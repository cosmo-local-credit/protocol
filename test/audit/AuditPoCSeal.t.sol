// SPDX-License-Identifier: AGPL-3.0
// Proof-of-concept exploits and verification tests for the seal state machine,
// proxy-upgrade safety, registry call surface, fee-domain boundaries and
// SwapRouter loop bounds. Companion to AuditPoC.t.sol; findings are written up
// in audit/AUDIT.md.
//
// As in AuditPoC.t.sol, a PASSING test whose name describes a defect means the
// defect is PRESENT. Tests named `*_search`, `*_exhaustive`, `*_fuzz`,
// `*_roundtrip*` and `*_LoopBounds` are the opposite: they assert properties
// that HOLD, and document candidates that were investigated and discarded.
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {SwapPool} from "../../src/SwapPool.sol";
import {SwapRouter} from "../../src/SwapRouter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {ILimiter} from "../../src/interfaces/ILimiter.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";

contract AuditPoCSealTest is Test {
    uint256 constant PPM = 1_000_000;
    uint256 constant DEFAULT_FEE_PPM = 10_000;

    SwapPool poolImpl;
    VsRegistry registry;
    VsLimiter limiter;
    VsFeePolicy feePolicy;
    VsPfc pfc;

    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");
    address attacker = makeAddr("attacker");
    address user = makeAddr("user");

    event SealStateChange(bool indexed _final, uint256 _sealState);

    function setUp() public {
        poolImpl = new SwapPool();
        registry = new VsRegistry();
        limiter = new VsLimiter();
        feePolicy = new VsFeePolicy();
        pfc = new VsPfc();
    }

    function _pool(address quoter_, bool decoupled) internal returns (SwapPool p) {
        p = SwapPool(LibClone.clone(address(poolImpl)));
        p.initialize(
            "Pool",
            "P",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(registry),
            address(limiter),
            quoter_,
            decoupled,
            address(pfc)
        );
    }

    function _allow(SwapPool p, address t, uint256 lim) internal {
        registry.add(t);
        limiter.setLimit(t, address(p), lim);
    }

    // =====================================================================
    // A. SEAL STATE MACHINE
    // =====================================================================

    /// A1: seal(0) is accepted, mutates nothing, never reverts with
    ///     AlreadyLocked, and still emits SealStateChange.
    function test_A1_seal_zero_isRepeatableNoop() public {
        SwapPool p = _pool(address(0), false);

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit SealStateChange(false, 0);
        assertEq(p.seal(0), 0, "seal(0) returns unchanged state");
        // Repeatable: no AlreadyLocked guard because (0 & sealState) == 0 always.
        p.seal(0);
        p.seal(0);
        assertEq(p.sealState(), 0, "still nothing sealed");

        // Even after a real seal, seal(0) keeps succeeding.
        p.seal(7);
        assertEq(p.sealState(), 7);
        vm.expectEmit(true, false, false, true);
        emit SealStateChange(false, 7); // not fully sealed until bits 8 and 16
        p.seal(0);
        vm.stopPrank();
    }

    /// A2: isSealed() accepts every mask up to and including maxSealState.
    ///     One past it reverts. (Previously isSealed(maxSealState) reverted.)
    function test_A2_isSealed_acceptsFullMask() public {
        SwapPool p = _pool(address(0), false);
        vm.prank(owner);
        p.seal(31);

        assertTrue(p.isSealed(0), "isSealed(0) is the full-seal query");
        assertTrue(p.isSealed(1));
        assertTrue(p.isSealed(7));
        assertTrue(p.isSealed(31));
        vm.expectRevert(SwapPool.InvalidState.selector);
        p.isSealed(32);
        assertEq(p.maxSealState(), 31);
    }

    /// A3: partial overlap makes combined masks unusable - after sealing bit 1
    ///     the owner can no longer use any mask containing bit 1.
    function test_A3_seal_partialOverlapReverts() public {
        SwapPool p = _pool(address(0), false);
        vm.startPrank(owner);
        p.seal(1);
        vm.expectRevert(SwapPool.AlreadyLocked.selector);
        p.seal(3); // wants to add bit 2, blocked by the already-set bit 1
        p.seal(6); // must be spelled without bit 1
        assertEq(p.sealState(), 7);
        vm.stopPrank();
    }

    /// A4 (FIXED): a fully sealed pool cannot rewrite tokenRegistry or
    ///     tokenLimiter, so an honest junk ERC20 cannot drain it.
    function test_A4_fullySealedPool_registryAndLimiterAreSealed() public {
        VsERC20 real = new VsERC20("Real", "REAL", 18);
        VsERC20 junk = new VsERC20("Junk", "JUNK", 18);

        SwapPool p = _pool(address(0), false); // no quoter => 1:1
        _allow(p, address(real), type(uint256).max);
        real.mint(address(p), 100_000e18);

        vm.prank(owner);
        p.seal(31);
        assertTrue(p.isSealed(0), "pool is fully sealed");

        junk.mint(attacker, 100_000e18);
        vm.startPrank(attacker);
        junk.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.UnauthorizedToken.selector);
        p.withdraw(address(real), address(junk), 100_000e18);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setTokenRegistry(address(0));
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setTokenLimiter(address(0));
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(SwapPool.UnauthorizedToken.selector);
        p.withdraw(address(real), address(junk), 100_000e18);

        assertEq(real.balanceOf(attacker), 0, "sealed pool untouched");
        assertEq(real.balanceOf(address(p)), 100_000e18);
    }

    /// A4b (FIXED): the same two setters cannot brick a fully sealed pool.
    function test_A4b_fullySealedPool_cannotBeBrickedByRegistry() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        b.mint(address(p), 1_000e18);
        a.mint(user, 10e18);

        vm.prank(owner);
        p.seal(31);

        VsRegistry deny = new VsRegistry(); // whitelists nothing
        vm.prank(owner);
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setTokenRegistry(address(deny));

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 1e18);
        vm.stopPrank();

        assertEq(b.balanceOf(user), 1e18, "honest swap still works");
    }

    /// A5: bringing tokenRegistry and tokenLimiter under the bitmask created a
    ///     second way to lose them: sealing a gate that was never configured
    ///     would freeze the pool as permanently ungated while isSealed(0)
    ///     advertised a complete seal, and any junk ERC20 could then drain it.
    ///     seal() now requires each gate to hold an address before its bit can
    ///     be locked, matching EthFaucet.seal().
    function test_A5_sealingUnsetGates_isRejected() public {
        VsERC20 real = new VsERC20("Real", "REAL", 18);
        VsERC20 junk = new VsERC20("Junk", "JUNK", 18);

        SwapPool p = SwapPool(LibClone.clone(address(poolImpl)));
        p.initialize(
            "Pool",
            "P",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(0),
            address(0),
            address(0),
            false,
            address(pfc)
        );
        real.mint(address(p), 100_000e18);

        vm.startPrank(owner);
        vm.expectRevert(SwapPool.InvalidState.selector);
        p.seal(31);
        vm.expectRevert(SwapPool.InvalidState.selector);
        p.seal(8);
        vm.expectRevert(SwapPool.InvalidState.selector);
        p.seal(16);
        vm.stopPrank();

        assertEq(p.sealState(), 0, "no gate bit was locked");
        assertFalse(p.isSealed(0), "and the pool never claims a full seal");

        // The owner's remedy is still open: wire the gates, then seal.
        vm.startPrank(owner);
        p.setTokenRegistry(address(registry));
        p.setTokenLimiter(address(limiter));
        assertEq(p.seal(31), 31);
        vm.stopPrank();

        // Which is what makes the seal worth anything: junk is now rejected
        // and can never be admitted again.
        junk.mint(attacker, 100_000e18);
        vm.startPrank(attacker);
        junk.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.UnauthorizedToken.selector);
        p.withdraw(address(real), address(junk), 100_000e18);
        vm.stopPrank();

        assertEq(real.balanceOf(attacker), 0, "sealed pool not drained");
        assertEq(real.balanceOf(address(p)), 100_000e18, "pool intact");
    }

    // =====================================================================
    // B. withdrawLiquidity vs fees[]
    // =====================================================================

    /// B1: withdrawLiquidity ignores fees[] entirely. In feesDecoupled mode
    ///     the owner takes the reserved fees (which belong to feeAddress),
    ///     leaves fees[token] > balanceOf(token), and thereby DoSes every
    ///     future swap of that tokenOut. No hostile token, no reentrancy.
    function test_B1_withdrawLiquidity_stealsReservedFees_andDoSesPool() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);

        SwapPool p = _pool(address(0), true); // feesDecoupled = true
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 100_000); // 10%

        b.mint(address(p), 1_000e18);
        a.mint(user, 100e18);

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 100e18);
        vm.stopPrank();

        assertEq(p.fees(address(b)), 10e18, "10 B reserved for feeAddress");
        assertEq(b.balanceOf(address(p)), 910e18);

        // Owner sweeps the whole balance, including the reserved 10.
        address thief = makeAddr("thief");
        vm.prank(owner);
        p.withdrawLiquidity(address(b), thief, 910e18);

        assertEq(b.balanceOf(thief), 910e18, "owner took feeAddress's 10 B too");
        assertGt(p.fees(address(b)), b.balanceOf(address(p)), "fees[] now exceeds balance");

        // Consequence 1: fee collection for feeAddress is permanently broken.
        vm.prank(owner);
        vm.expectRevert();
        p.withdraw(address(b));

        // Consequence 2: available liquidity is pinned at 0, so even a fresh
        // donation smaller than fees[] cannot restart the pool.
        b.mint(address(p), 9e18);
        a.mint(user, 1e18);
        vm.startPrank(user);
        vm.expectRevert(SwapPool.InsufficientBalance.selector);
        p.withdraw(address(b), address(a), 1e18);
        vm.stopPrank();
    }

    /// B2: withdrawLiquidity is not sealable either, so the FEEADDRESS seal
    ///     (the commitment "fees go to this beneficiary") is worthless.
    function test_B2_feeAddressSeal_doesNotProtectFees() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), true);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 100_000);
        b.mint(address(p), 1_000e18);
        a.mint(user, 100e18);

        vm.prank(owner);
        p.seal(7); // everything sealed, including feeAddress

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 100e18);
        vm.stopPrank();

        uint256 reserved = p.fees(address(b));
        assertEq(reserved, 10e18);

        vm.prank(owner);
        p.withdrawLiquidity(address(b), owner, reserved);
        assertEq(b.balanceOf(owner), reserved, "sealed beneficiary's fees taken anyway");
    }

    // =====================================================================
    // C. UPGRADE SAFETY
    // =====================================================================

    /// C1 (FIXED): isSealed(0) uses the stored fullSealMask, so raising
    ///     maxSealState in an upgrade does not flip already-fully-sealed pools.
    function test_C1_upgradeAddingSealBit_keepsExistingPoolsSealed() public {
        ERC1967Factory factory = new ERC1967Factory();
        address admin = makeAddr("proxyAdmin");

        bytes memory initData = abi.encodeCall(
            SwapPool.initialize,
            (
                "Pool",
                "P",
                18,
                owner,
                address(feePolicy),
                feeAddress,
                address(registry),
                address(limiter),
                address(0),
                false,
                address(pfc)
            )
        );
        SwapPool p = SwapPool(factory.deployAndCall(address(poolImpl), admin, initData));

        vm.prank(owner);
        p.seal(31);
        assertTrue(p.isSealed(0), "V1: fully sealed");
        assertEq(p.fullSealMask(), 31);

        VsSwapPoolV2 v2 = new VsSwapPoolV2();
        vm.prank(admin);
        factory.upgrade(address(p), address(v2));

        assertEq(uint256(VsSwapPoolV2(address(p)).sealState()), 31, "storage untouched");
        assertEq(uint256(VsSwapPoolV2(address(p)).maxSealState()), 63, "constant changed with the code");
        assertEq(uint256(VsSwapPoolV2(address(p)).fullSealMask()), 31, "mask stays at the sealed-in definition");
        assertTrue(VsSwapPoolV2(address(p)).isSealed(0), "still fully sealed under the stored mask");
    }

    /// C2: sealState is the LAST declared variable and shares slot 10 with
    ///     feesDecoupled (offset 0 / offset 1) with no reserved gap. An upgrade
    ///     that groups a new config flag next to feesDecoupled - the natural
    ///     place for it - shifts sealState by one byte and un-seals every pool,
    ///     while inheriting the old seal bits as the new flag's value.
    function test_C2_storagePacking_shiftsSealState() public {
        ERC1967Factory factory = new ERC1967Factory();
        address admin = makeAddr("proxyAdmin2");
        bytes memory initData = abi.encodeCall(
            SwapPool.initialize,
            (
                "Pool",
                "P",
                18,
                owner,
                address(feePolicy),
                feeAddress,
                address(registry),
                address(limiter),
                address(0),
                true,
                address(pfc)
            )
        );
        SwapPool p = SwapPool(factory.deployAndCall(address(poolImpl), admin, initData));

        vm.prank(owner);
        p.seal(31);
        assertEq(vm.load(address(p), bytes32(uint256(10))), bytes32(uint256(0x1f01)));

        VsSwapPoolV3 v3 = new VsSwapPoolV3();
        vm.prank(admin);
        factory.upgrade(address(p), address(v3));

        assertEq(uint256(VsSwapPoolV3(address(p)).sealState()), 0, "REGRESSION: fully unsealed");
        assertTrue(VsSwapPoolV3(address(p)).paused(), "new flag inherited the old seal bits");
        // Sealed fields are writable again.
        vm.prank(owner);
        VsSwapPoolV3(address(p)).setQuoter(address(0xdead));
        assertEq(VsSwapPoolV3(address(p)).quoter(), address(0xdead));
    }

    /// C2b (residual): an upgrade still defeats seal if the proxy admin is the
    ///      owner. ge-publish now refuses that default; this records that the
    ///      EVM path remains if an operator ignores the tooling check.
    function test_C2b_sealCircumventedByUpgrade_sameKey() public {
        ERC1967Factory factory = new ERC1967Factory();
        address ownerAndAdmin = owner; // == the tooling default

        bytes memory initData = abi.encodeCall(
            SwapPool.initialize,
            (
                "Pool",
                "P",
                18,
                ownerAndAdmin,
                address(feePolicy),
                feeAddress,
                address(registry),
                address(limiter),
                address(0x1111),
                false,
                address(pfc)
            )
        );
        SwapPool p = SwapPool(factory.deployAndCall(address(poolImpl), ownerAndAdmin, initData));

        vm.startPrank(ownerAndAdmin);
        p.seal(31);
        assertTrue(p.isSealed(0), "publicly verifiable: fully sealed forever");
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setQuoter(address(0xdead));
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setFeeAddress(address(0xdead));
        vm.stopPrank();

        // Same key, one transaction, seal gone.
        VsSwapPoolNoSeal free = new VsSwapPoolNoSeal();
        vm.prank(ownerAndAdmin);
        factory.upgrade(address(p), address(free));

        vm.startPrank(ownerAndAdmin);
        VsSwapPoolNoSeal(address(p)).setQuoter(address(0xdead));
        VsSwapPoolNoSeal(address(p)).setFeeAddress(address(0xdead));
        VsSwapPoolNoSeal(address(p)).setFeePolicy(address(0xdead));
        vm.stopPrank();

        assertEq(VsSwapPoolNoSeal(address(p)).quoter(), address(0xdead));
        assertEq(VsSwapPoolNoSeal(address(p)).feeAddress(), address(0xdead));
        assertEq(uint256(VsSwapPoolNoSeal(address(p)).sealState()), 31, "sealState still says 31");
    }

    /// C3: initialize() has no caller restriction. The shipped tooling deploys
    ///     and initializes atomically, but a proxy created WITHOUT init data is
    ///     seizable by anyone. Recorded to bound the claim.
    function test_C3_uninitializedProxy_isSeizable() public {
        ERC1967Factory factory = new ERC1967Factory();
        address p = factory.deploy(address(poolImpl), makeAddr("admin3")); // no init call

        vm.prank(attacker);
        SwapPool(p)
            .initialize(
                "Hijacked",
                "HJ",
                18,
                attacker,
                address(0),
                attacker,
                address(0),
                address(0),
                address(0),
                false,
                address(0)
            );
        assertEq(SwapPool(p).owner(), attacker, "unauthenticated initialize");

        // The implementation itself IS protected.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        poolImpl.initialize(
            "x", "x", 18, attacker, address(0), attacker, address(0), address(0), address(0), false, address(0)
        );
    }

    // =====================================================================
    // D. mustAllowedToken
    // =====================================================================

    /// D1: a registry with a permissive fallback that returns a truthy word
    ///     silently whitelists EVERY token. No returndatasize check and no
    ///     interface check. The registry is still writable here because this
    ///     pool is unsealed.
    function test_D1_fallbackRegistry_whitelistsEverything() public {
        VsERC20 junk = new VsERC20("Junk", "JUNK", 18);
        VsERC20 real = new VsERC20("Real", "REAL", 18);
        VsTruthyFallback bad = new VsTruthyFallback();

        SwapPool p = _pool(address(0), false);
        _allow(p, address(real), type(uint256).max);
        real.mint(address(p), 1_000e18);
        junk.mint(attacker, 1_000e18);
        limiter.setLimit(address(junk), address(p), type(uint256).max);

        vm.prank(owner);
        p.setTokenRegistry(address(bad));

        vm.startPrank(attacker);
        junk.approve(address(p), type(uint256).max);
        p.withdraw(address(real), address(junk), 1_000e18); // silently allowed
        vm.stopPrank();
        assertEq(real.balanceOf(attacker), 1_000e18);
    }

    /// D2: exactly which malformed registry replies pass and which revert.
    function test_D2_registryReturnShapes() public {
        SwapPool p = _pool(address(0), false);
        VsERC20 t = new VsERC20("T", "T", 18);
        limiter.setLimit(address(t), address(p), type(uint256).max);
        t.mint(user, 10e18);
        vm.prank(user);
        t.approve(address(p), type(uint256).max);

        // (a) >32 bytes with a leading true word: ACCEPTED (trailing data ignored)
        VsRawRegistry r = new VsRawRegistry();
        r.setRaw(abi.encode(true, uint256(12345)));
        vm.prank(owner);
        p.setTokenRegistry(address(r));
        vm.prank(user);
        p.deposit(address(t), 1e18);
        emit log_string("64-byte reply with leading true: ACCEPTED");

        // (b) non-boolean truthy word
        r.setRaw(abi.encode(uint256(2)));
        vm.prank(user);
        (bool ok2,) = address(p).call(abi.encodeCall(SwapPool.deposit, (address(t), 1e18)));
        emit log_named_string("uint256(2) as bool", ok2 ? "ACCEPTED" : "reverted");

        // (c) dirty high bits, low byte 1
        r.setRaw(abi.encodePacked(bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001))));
        vm.prank(user);
        (bool ok3,) = address(p).call(abi.encodeCall(SwapPool.deposit, (address(t), 1e18)));
        emit log_named_string("dirty-high-bits bool", ok3 ? "ACCEPTED" : "reverted");

        // (d) short reply (31 bytes)
        r.setRaw(new bytes(31));
        vm.prank(user);
        (bool ok4, bytes memory e4) = address(p).call(abi.encodeCall(SwapPool.deposit, (address(t), 1e18)));
        emit log_named_string("31-byte reply", ok4 ? "ACCEPTED" : "reverted");
        emit log_named_uint("  revert data length", e4.length);

        // (e) registry with no code at all: call succeeds, decode blows up
        vm.prank(owner);
        p.setTokenRegistry(makeAddr("codelessRegistry"));
        vm.prank(user);
        (bool ok5, bytes memory e5) = address(p).call(abi.encodeCall(SwapPool.deposit, (address(t), 1e18)));
        assertFalse(ok5);
        assertEq(e5.length, 0, "codeless registry => EMPTY revert, not RegistryCallFailed");
        emit log_string("codeless registry: reverts with NO error data (RegistryCallFailed unreachable)");
    }

    /// D3: RegistryCallFailed only fires when the registry actively reverts.
    function test_D3_registryCallFailed_reachability() public {
        SwapPool p = _pool(address(0), false);
        VsERC20 t = new VsERC20("T", "T", 18);
        limiter.setLimit(address(t), address(p), type(uint256).max);
        t.mint(user, 10e18);
        vm.startPrank(user);
        t.approve(address(p), type(uint256).max);
        vm.stopPrank();

        VsRevertingRegistry rr = new VsRevertingRegistry();
        vm.prank(owner);
        p.setTokenRegistry(address(rr));
        vm.prank(user);
        vm.expectRevert(SwapPool.RegistryCallFailed.selector);
        p.deposit(address(t), 1e18);
    }

    // =====================================================================
    // E. Permissionless deposit + limiter cap
    // =====================================================================

    /// E1: deposit() is permissionless and the limiter caps the POOL's total
    ///     balance, so anyone can saturate the cap and block the entire input
    ///     side of the pool for everyone. The griefer keeps a claim on the
    ///     tokens (they are pool liquidity), so the attack is near-free.
    function test_E1_permissionlessDeposit_capSaturationDoS() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        registry.add(address(a));
        registry.add(address(b));
        limiter.setLimit(address(a), address(p), 1_000e18); // risk cap on A
        limiter.setLimit(address(b), address(p), type(uint256).max);

        a.mint(address(p), 900e18);
        b.mint(address(p), 100_000e18);

        // Griefer tops A up to exactly the cap.
        a.mint(attacker, 100e18);
        vm.startPrank(attacker);
        a.approve(address(p), type(uint256).max);
        p.deposit(address(a), 100e18);
        vm.stopPrank();
        assertEq(a.balanceOf(address(p)), 1_000e18);

        // Every honest A->B swap now reverts, for any size, forever.
        a.mint(user, 500e18);
        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.LimitExceeded.selector);
        p.withdraw(address(b), address(a), 1e18);
        vm.expectRevert(SwapPool.LimitExceeded.selector);
        p.withdraw(address(b), address(a), 1);
        vm.stopPrank();

        // The griefer can pull their capital back out whenever they like.
        b.mint(attacker, 200e18);
        vm.startPrank(attacker);
        b.approve(address(p), type(uint256).max);
        p.withdraw(address(a), address(b), 100e18);
        vm.stopPrank();
        assertGt(a.balanceOf(attacker), 0, "griefing capital is recoverable");
    }

    // =====================================================================
    // F. ALGEBRA: _reverseNetToQuoted vs _calcProtocolFee
    // =====================================================================

    /// F1: exhaustive-ish search for a branch disagreement between
    ///     `_feePpm >= DEFAULT_FEE_PPM` and `totalFee >= assumedFee`.
    ///     Records every (quotedValue, feePpm) where the two disagree and
    ///     whether the resulting protocol fee actually differs.
    function test_F1_branchDisagreement_search() public {
        uint256 disagreements;
        uint256 valueDiffs;
        uint256[6] memory qs = [uint256(1), 99, 100, 1e6, 12345, 1e18];
        for (uint256 f = 0; f < 20_000; f += 1) {
            for (uint256 qi = 0; qi < 6; qi++) {
                uint256 q = qs[qi];
                uint256 totalFee = (q * f) / PPM;
                uint256 assumedFee = (q * DEFAULT_FEE_PPM) / PPM;
                bool reverseBranchHigh = f >= DEFAULT_FEE_PPM;
                bool forwardBranchHigh = totalFee >= assumedFee;
                if (reverseBranchHigh != forwardBranchHigh) {
                    disagreements++;
                    if (totalFee != assumedFee) valueDiffs++;
                }
            }
        }
        emit log_named_uint("branch-condition disagreements", disagreements);
        emit log_named_uint("  of which change effectiveFee", valueDiffs);
        assertEq(valueDiffs, 0, "disagreements are always value-neutral (max() collapses them)");
    }

    /// F2: fuzz the documented round-trip property with NO quoter, across both
    ///     branches and the boundary, including a protocol fee.
    function test_F2_getAmountIn_roundtrip_fuzz(uint256 out_, uint16 fSeed, uint32 pSeed) public {
        uint256 desiredOut = bound(out_, 1, 1e30);
        uint256 f = bound(uint256(fSeed), 0, 20_000); // straddles DEFAULT_FEE_PPM
        uint256 pfee = bound(uint256(pSeed), 0, PPM);

        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        feePolicy.setFee(address(a), address(b), f);
        pfc.setFee(pfee);
        pfc.setRecipient(pfee == 0 ? address(0) : makeAddr("proto"));

        uint256 amountIn = p.getAmountIn(address(b), address(a), desiredOut);
        uint256 actualOut = p.getAmountOut(address(b), address(a), amountIn);
        assertGe(actualOut, desiredOut, "getAmountIn under-delivers");
    }

    /// F3: exhaustive small-value sweep of the same property (no fuzzer luck).
    ///     Fee combinations restricted to the region where BOTH directions are
    ///     defined - see F5/F6 for the boundary where they are not.
    function test_F3_getAmountIn_roundtrip_exhaustive() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        uint256[6] memory feeList = [uint256(0), 1, 9_999, 10_000, 10_001, 400_000];
        uint256[4] memory pList = [uint256(0), 1, 100_000, PPM];
        uint256 failures;
        uint256 cases;
        for (uint256 i = 0; i < feeList.length; i++) {
            feePolicy.setFee(address(a), address(b), feeList[i]);
            for (uint256 j = 0; j < pList.length; j++) {
                pfc.setFee(pList[j]);
                pfc.setRecipient(pList[j] == 0 ? address(0) : makeAddr("proto"));
                for (uint256 d = 1; d <= 200; d++) {
                    cases++;
                    uint256 amountIn = p.getAmountIn(address(b), address(a), d);
                    if (p.getAmountOut(address(b), address(a), amountIn) < d) failures++;
                }
            }
        }
        emit log_named_uint("cases", cases);
        emit log_named_uint("round-trip failures", failures);
        assertEq(failures, 0);
    }

    /// F5 (FIXED): at f*(PPM+p) == PPM^2 the reverse path reverts FeeTooHigh
    ///     and the forward path / swap revert InsufficientOutput. The user's
    ///     input is not taken.
    function test_F5_denominatorZero_revertsNamedError() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);

        feePolicy.setFee(address(a), address(b), 800_000); // 80% pool fee
        pfc.setFee(250_000); // 25% protocol fee
        address proto = makeAddr("proto");
        pfc.setRecipient(proto);
        assertEq(800_000 * (PPM + 250_000), PPM * PPM);

        b.mint(address(p), 1_000e18);
        a.mint(user, 100e18);

        // Both directions now reject the configuration by the same predicate,
        // and name the cause rather than the symptom.
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountOut(address(b), address(a), 100e18);

        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountIn(address(b), address(a), 1e18);

        // Including at dust, where both fees would otherwise floor to zero and
        // slip past an amount-only check.
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountOut(address(b), address(a), 1);

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.withdraw(address(b), address(a), 100e18);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.withdraw(address(b), address(a), 1);
        vm.stopPrank();

        assertEq(a.balanceOf(user), 100e18, "input not taken");
        assertEq(b.balanceOf(user), 0);
        assertEq(p.fees(address(b)), 0);
        assertEq(b.balanceOf(proto), 0);
    }

    /// F6 (FIXED): a protocol-fee bump that pushes a live pool out of domain
    ///     reverts FeeTooHigh instead of Panic(0x11), and does not take input.
    function test_F6_protocolFeeOwner_outOfDomainRevertsFeeTooHigh() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        b.mint(address(p), 1_000e18);

        feePolicy.setFee(address(a), address(b), 600_000); // 60% - high but legal
        pfc.setFee(100_000); // 10%
        pfc.setRecipient(makeAddr("proto"));

        uint256 before = p.getAmountIn(address(b), address(a), 1e18);
        assertGt(before, 0);

        pfc.setFee(700_000);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountIn(address(b), address(a), 1e18);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountOut(address(b), address(a), 1e18);

        a.mint(user, 10e18);
        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.withdraw(address(b), address(a), 1e18);
        vm.stopPrank();

        assertEq(a.balanceOf(user), 10e18, "input not taken");
    }

    /// F7: map the boundary explicitly.
    function test_F7_boundaryTable() public {
        uint256[5] memory ps = [uint256(0), 100_000, 250_000, 700_000, PPM];
        for (uint256 i = 0; i < ps.length; i++) {
            uint256 p = ps[i];
            uint256 bound = (PPM * PPM) / (PPM + p); // first f that kills case 1
            emit log_named_uint("protocolFeePpm", p);
            emit log_named_uint("  max safe poolFeePpm", bound - 1);
        }
    }

    /// F4: how much does the reverse formula OVER-charge? (quantifies the
    ///     ceiling + the unconditional +1)
    function test_F4_getAmountIn_overcharge() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        feePolicy.setFee(address(a), address(b), 10_000);
        uint256 need = p.getAmountIn(address(b), address(a), 99e18);
        emit log_named_uint("input for 99e18 out at 1% fee", need);
        emit log_named_uint("actual out for that input", p.getAmountOut(address(b), address(a), need));
    }

    // =====================================================================
    // G. SwapRouter
    // =====================================================================

    /// G1: reverse loop bounds - assert every hop is visited exactly once, in
    ///     reverse order, with no index skipped and no out-of-range access.
    function test_G1_router_reverseLoopBounds() public {
        SwapRouter router = new SwapRouter();
        VsERC20 t0 = new VsERC20("T0", "T0", 18);
        VsERC20 t1 = new VsERC20("T1", "T1", 18);
        VsERC20 t2 = new VsERC20("T2", "T2", 18);
        VsERC20 t3 = new VsERC20("T3", "T3", 18);

        VsTracer tracer = new VsTracer();
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](3);
        path[0] = SwapRouter.Hop(address(tracer), address(t0), address(t1));
        path[1] = SwapRouter.Hop(address(tracer), address(t1), address(t2));
        path[2] = SwapRouter.Hop(address(tracer), address(t2), address(t3));

        router.quoteExactOutput(path, 1000);
        // 3 hops, visited last-to-first
        assertEq(tracer.count(), 3, "each hop visited exactly once");
        assertEq(tracer.seenAt(0), address(t3), "first call is the LAST hop's tokenOut");
        assertEq(tracer.seenAt(1), address(t2));
        assertEq(tracer.seenAt(2), address(t1));

        tracer.reset();
        router.quoteExactInput(path, 1000);
        assertEq(tracer.count(), 3);
        assertEq(tracer.seenAt(0), address(t1), "forward loop starts at hop 0");
        assertEq(tracer.seenAt(2), address(t3));
    }

    /// G2: does the per-hop +1 compound dangerously over a long path?
    function test_G2_router_plusOneCompounding() public {
        SwapRouter router = new SwapRouter();
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        feePolicy.setFee(address(a), address(b), 10_000); // 1%

        for (uint256 n = 1; n <= 32; n *= 2) {
            SwapRouter.Hop[] memory path = new SwapRouter.Hop[](n);
            for (uint256 i = 0; i < n; i++) {
                path[i] = SwapRouter.Hop(address(p), address(a), address(b));
            }
            uint256 need = router.quoteExactOutput(path, 1);
            uint256 got = router.quoteExactInput(path, need);
            emit log_named_uint("hops", n);
            emit log_named_uint("  input needed for 1 unit out", need);
            emit log_named_uint("  actual out", got);
            assertGe(got, 1);
        }
    }

    /// H1: mustAllowedToken uses a raw .call, so the registry gets FULL call
    ///     context and can mutate state / re-enter. The analogous limiter check
    ///     is a `view` interface call and therefore a STATICCALL. Asymmetry.
    function test_H1_registryCall_isNotStaticcall() public {
        SwapPool p = _pool(address(0), false);
        VsERC20 t = new VsERC20("T", "T", 18);
        limiter.setLimit(address(t), address(p), type(uint256).max);
        t.mint(user, 10e18);

        VsStatefulRegistry sr = new VsStatefulRegistry();
        vm.prank(owner);
        p.setTokenRegistry(address(sr));
        vm.startPrank(user);
        t.approve(address(p), type(uint256).max);
        p.deposit(address(t), 1e18);
        vm.stopPrank();
        assertEq(sr.hits(), 1, "registry wrote storage during have() => not a staticcall");

        // The limiter cannot: `limitOf` is `view`, compiled to STATICCALL.
        VsStatefulLimiter sl = new VsStatefulLimiter();
        vm.prank(owner);
        p.setTokenLimiter(address(sl));
        vm.prank(user);
        (bool ok,) = address(p).call(abi.encodeCall(SwapPool.deposit, (address(t), 1e18)));
        assertFalse(ok, "state-writing limiter reverts => STATICCALL");
    }

    /// H2: SwapPool never consults IFeePolicy.isActive() (nor
    ///     IProtocolFeeController.isActive() directly), so a policy that
    ///     reports itself disabled still has its fees charged.
    function test_H2_isActive_neverConsulted() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        VsInactiveFeePolicy dead = new VsInactiveFeePolicy();
        dead.setFee(address(a), address(b), 100_000); // 10%

        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        vm.prank(owner);
        p.setFeePolicy(address(dead));
        assertFalse(dead.isActive(), "policy reports itself OFF");

        b.mint(address(p), 1_000e18);
        a.mint(user, 100e18);
        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 100e18);
        vm.stopPrank();
        assertEq(p.fees(address(b)), 10e18, "fee charged anyway");
    }

    /// H3: withdraw(token, 0) succeeds and emits a Collect event even when
    ///     fees[token] == 0, while withdraw(token) reverts. Inconsistent.
    function test_H3_zeroValueFeeCollect() public {
        SwapPool p = _pool(address(0), false);
        VsERC20 b = new VsERC20("B", "B", 18);
        vm.prank(owner);
        vm.expectRevert(SwapPool.InsufficientFees.selector);
        p.withdraw(address(b));

        vm.prank(owner);
        assertEq(p.withdraw(address(b), 0), 0, "zero-value collect succeeds");
    }

    /// H4 (partly fixed): the Swap event now carries the NET amount the
    /// recipient received, so settlement is verifiable from logs and the
    /// protocol fee is recoverable as amountIn - amountOut - fee on a 1:1 pair.
    /// The protocol fee still has no dedicated event.
    function test_H4_swapEventReportsNetSettlement() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000);
        pfc.setFee(100_000);
        pfc.setRecipient(makeAddr("proto"));
        b.mint(address(p), 1_000e18);
        a.mint(user, 100e18);

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        vm.recordLogs();
        p.withdraw(address(b), address(a), 100e18);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapSig = keccak256("Swap(address,address,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == swapSig) {
                (address tOut, uint256 amtIn, uint256 amtOut, uint256 fee) =
                    abi.decode(logs[i].data, (address, uint256, uint256, uint256));
                assertEq(tOut, address(b));
                assertEq(amtIn, 100e18);
                assertEq(amtOut, 98_9e17, "amountOut is the NET amount transferred");
                assertEq(fee, 1e18, "fee is still the pool fee only");
                assertEq(b.balanceOf(user), amtOut, "the log matches what the user received");
                assertEq(amtIn - amtOut - fee, 1e17, "protocol fee is derivable");
            }
        }
    }

    /// H5: protocolFeeController has NO setter and is not sealable, so a pool
    ///     cannot defend itself against a protocol fee recipient that can no
    ///     longer receive the token (blacklist / reverting contract). Every
    ///     swap on every affected pool reverts.
    function test_H5_unreceivableProtocolRecipient_bricksAllSwaps() public {
        VsERC20 a = new VsERC20("A", "A", 18);
        VsBlacklistERC20 b = new VsBlacklistERC20();
        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000);
        address proto = makeAddr("protoRecipient");
        pfc.setFee(100_000);
        pfc.setRecipient(proto);

        b.mint(address(p), 1_000e18);
        a.mint(user, 100e18);
        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 10e18); // works today
        vm.stopPrank();

        b.blacklist(proto); // token issuer freezes the protocol recipient

        vm.startPrank(user);
        vm.expectRevert("blacklisted");
        p.withdraw(address(b), address(a), 10e18);
        vm.stopPrank();

        // SwapPool has no lever: protocolFeeController has no setter.
        vm.prank(owner);
        (bool ok,) = address(p).call(abi.encodeWithSignature("setProtocolFeeController(address)", address(0)));
        assertFalse(ok, "no setter exists");
    }

    /// G3: the router never checks tokenOut[i] == tokenIn[i+1].
    function test_G3_router_pathContinuityUnchecked() public {
        SwapRouter router = new SwapRouter();
        VsERC20 a = new VsERC20("A", "A", 18);
        VsERC20 b = new VsERC20("B", "B", 18);
        VsERC20 c = new VsERC20("C", "C", 18);
        VsERC20 d = new VsERC20("D", "D", 18);
        SwapPool p = _pool(address(0), false);
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](2);
        path[0] = SwapRouter.Hop(address(p), address(a), address(b));
        path[1] = SwapRouter.Hop(address(p), address(c), address(d)); // discontinuous
        uint256 outAmt = router.quoteExactInput(path, 1e18);
        emit log_named_uint("quote for a discontinuous path", outAmt);
        assertGt(outAmt, 0, "nonsense path still produces a confident quote");
    }
}

// ------------------------------------------------------------------ mocks

contract VsERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 v) public virtual {
        balanceOf[to] += v;
    }

    function approve(address sp, uint256 v) external returns (bool) {
        allowance[msg.sender][sp] = v;
        return true;
    }

    function transfer(address to, uint256 v) external virtual returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external virtual returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

contract VsRegistry {
    mapping(address => bool) private allowed;

    function add(address t) external {
        allowed[t] = true;
    }

    function have(address t) external view returns (bool) {
        return allowed[t];
    }
}

/// Returns a truthy 32-byte word for ANY calldata.
contract VsTruthyFallback {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(true);
    }
}

/// Returns caller-controlled raw bytes for any call.
contract VsRawRegistry {
    bytes private raw;

    function setRaw(bytes calldata b) external {
        raw = b;
    }

    fallback() external {
        bytes memory r = raw;
        assembly {
            return(add(r, 0x20), mload(r))
        }
    }
}

contract VsBlacklistERC20 is VsERC20 {
    mapping(address => bool) public blocked;

    constructor() VsERC20("BL", "BL", 18) {}

    function blacklist(address a) external {
        blocked[a] = true;
    }

    function transfer(address to, uint256 v) external override returns (bool) {
        require(!blocked[to], "blacklisted");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

contract VsStatefulRegistry {
    uint256 public hits;

    function have(address) external returns (bool) {
        hits++;
        return true;
    }
}

contract VsStatefulLimiter {
    uint256 public hits;

    function limitOf(address, address) external returns (uint256) {
        hits++;
        return type(uint256).max;
    }
}

contract VsInactiveFeePolicy is IFeePolicy {
    mapping(address => mapping(address => uint256)) private f;

    function setFee(address i, address o, uint256 v) external {
        f[i][o] = v;
    }

    function getFee(address i, address o) external view returns (uint256) {
        return f[i][o];
    }

    function isActive() external pure returns (bool) {
        return false;
    }
}

contract VsRevertingRegistry {
    function have(address) external pure returns (bool) {
        revert("nope");
    }
}

contract VsLimiter is ILimiter {
    mapping(address => mapping(address => uint256)) private limits;

    function setLimit(address t, address h, uint256 v) external {
        limits[t][h] = v;
    }

    function limitOf(address t, address h) external view returns (uint256) {
        return limits[t][h];
    }
}

contract VsFeePolicy is IFeePolicy {
    mapping(address => mapping(address => uint256)) private f;

    function setFee(address i, address o, uint256 v) external {
        f[i][o] = v;
    }

    function getFee(address i, address o) external view returns (uint256) {
        return f[i][o];
    }

    function isActive() external pure returns (bool) {
        return true;
    }
}

contract VsPfc is IProtocolFeeController {
    uint256 private fee;
    address private recipient;

    function setFee(uint256 v) external {
        fee = v;
    }

    function setRecipient(address r) external {
        recipient = r;
    }

    function getProtocolFee() external view returns (uint256) {
        return fee;
    }

    function getProtocolFeeRecipient() external view returns (address) {
        return recipient;
    }

    function isActive() external pure returns (bool) {
        return true;
    }
}

/// Records the order in which the router walks a path.
contract VsTracer {
    address[] private seen;

    function count() external view returns (uint256) {
        return seen.length;
    }

    function seenAt(uint256 i) external view returns (address) {
        return seen[i];
    }

    function reset() external {
        delete seen;
    }

    function getAmountIn(address outToken, address, uint256 v) external returns (uint256) {
        seen.push(outToken);
        return v;
    }

    function getAmountOut(address outToken, address, uint256 v) external returns (uint256) {
        seen.push(outToken);
        return v;
    }
}

// ---------------------------------------------------- upgrade-hazard variants

/// V2: same storage as SwapPool, maxSealState raised to 63. isSealed(0) still
/// reads the stored fullSealMask so already-sealed pools stay sealed.
contract VsSwapPoolV2 is Ownable, Initializable {
    error Sealed();
    error InvalidState();
    error AlreadyLocked();

    address public tokenRegistry;
    address public tokenLimiter;
    address public quoter;
    address public feeAddress;
    address public feePolicy;
    address public protocolFeeController;
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    mapping(address => uint256) public fees;
    bool public feesDecoupled;
    uint8 public sealState;
    uint240 private __sealSlotPadding;
    uint8 public fullSealMask;

    uint8 public constant maxSealState = 63; // was 31

    event SealStateChange(bool indexed _final, uint256 _sealState);

    function seal(uint8 _state) public onlyOwner returns (uint8) {
        if (_state > maxSealState) revert InvalidState();
        if (_state & sealState != 0) revert AlreadyLocked();
        sealState |= _state;
        uint8 mask = fullSealMask == 0 ? maxSealState : fullSealMask;
        emit SealStateChange(sealState & mask == mask, sealState);
        return sealState;
    }

    function isSealed(uint8 _state) public view returns (bool) {
        if (_state > maxSealState) revert InvalidState();
        if (_state == 0) {
            uint8 mask = fullSealMask == 0 ? maxSealState : fullSealMask;
            return sealState & mask == mask;
        }
        return _state & sealState == _state;
    }
}

/// Same storage layout, seal checks removed from the setters.
contract VsSwapPoolNoSeal is Ownable, Initializable {
    address public tokenRegistry;
    address public tokenLimiter;
    address public quoter;
    address public feeAddress;
    address public feePolicy;
    address public protocolFeeController;
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    mapping(address => uint256) public fees;
    bool public feesDecoupled;
    uint8 public sealState;

    function setQuoter(address a) public onlyOwner {
        quoter = a;
    }

    function setFeeAddress(address a) public onlyOwner {
        feeAddress = a;
    }

    function setFeePolicy(address a) public onlyOwner {
        feePolicy = a;
    }
}

/// V3: groups a new config flag next to feesDecoupled - the natural place -
/// which shifts sealState by one byte inside slot 10.
contract VsSwapPoolV3 is Ownable, Initializable {
    error Sealed();

    address public tokenRegistry;
    address public tokenLimiter;
    address public quoter;
    address public feeAddress;
    address public feePolicy;
    address public protocolFeeController;
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    mapping(address => uint256) public fees;
    bool public feesDecoupled;
    bool public paused; // <-- inserted
    uint8 public sealState;

    uint8 constant QUOTER_STATE = 4;
    uint8 public constant maxSealState = 7;

    function isSealed(uint8 _state) public view returns (bool) {
        if (_state >= maxSealState) revert();
        if (_state == 0) return sealState == maxSealState;
        return _state & sealState == _state;
    }

    function setQuoter(address _quoter) public onlyOwner {
        if (isSealed(QUOTER_STATE)) revert Sealed();
        quoter = _quoter;
    }
}
