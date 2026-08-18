// SPDX-License-Identifier: AGPL-3.0
// Audit PoC suite: GiftableToken / EthFaucet / PeriodSimple / CAT
//
// CONVENTION
//   * A PASSING test whose name describes a defect  => the defect IS PRESENT
//     (the assertions encode the broken behaviour).
//   * Tests suffixed `_holds` / `_isCorrect` / `_matchesSpec_holds` document a
//     property that genuinely holds (i.e. NOT a finding).
//
// All mock contracts are prefixed `Tk` to avoid clashes with other test files.
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../../src/GiftableToken.sol";
import "../../src/EthFaucet.sol";
import "../../src/PeriodSimple.sol";
import "../../src/CAT.sol";

/*//////////////////////////////////////////////////////////////////////////////
                                    MOCKS
//////////////////////////////////////////////////////////////////////////////*/

/// @dev Registry that answers `have()` truthfully (ABI-correct bool).
contract TkRegistry {
    mapping(address => bool) public listed;

    function set(address a, bool v) external {
        listed[a] = v;
    }

    function have(address a) external view returns (bool) {
        return listed[a];
    }
}

/// @dev Admits every address, for tests where the whitelist is not the subject.
contract TkOpenRegistry {
    function have(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Returns exactly ONE byte of returndata for any call.
contract TkShortReturnRegistry {
    fallback() external {
        assembly {
            mstore(0x00, 0x01)
            return(0x1f, 0x01)
        }
    }
}

/// @dev Returns a 32-byte word that is NOT a canonical ABI bool.
///      `abi.decode(_, (bool))` would reject 257; EthFaucet accepts it.
contract TkNonCanonicalBoolRegistry {
    uint256 public immutable word;

    constructor(uint256 w) {
        word = w;
    }

    function have(address) external view returns (uint256) {
        return word;
    }
}

/// @dev Records the faucet balance at the moment `poke()` is invoked, to prove
///      the payout ordering.
contract TkOrderPeriodChecker {
    address public faucet;
    uint256 public faucetBalanceAtPoke;
    bool public pokeCalled;

    function setFaucet(address f) external {
        faucet = f;
    }

    function have(address) external pure returns (bool) {
        return true;
    }

    function poke(address) external returns (bool) {
        pokeCalled = true;
        faucetBalanceAtPoke = faucet.balance;
        return true;
    }

    function next(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev `poke()` always answers false.
contract TkRefusingPeriodChecker {
    function have(address) external pure returns (bool) {
        return false;
    }

    function poke(address) external pure returns (bool) {
        return false;
    }

    function next(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @dev Registry that re-enters `giveTo()` while the faucet is mid-claim.
contract TkReentrantRegistry {
    EthFaucet public faucet;
    address public victim;
    bool public entered;

    function arm(address f, address v) external {
        faucet = EthFaucet(payable(f));
        victim = v;
        entered = false;
    }

    function have(address) external returns (bool) {
        if (!entered) {
            entered = true;
            faucet.giveTo(victim);
        }
        return true;
    }
}

/// @dev Recipient whose `receive()` costs far more than the 2300 gas stipend.
contract TkCostlyReceiver {
    uint256 public slot;

    receive() external payable {
        slot = slot + 1;
    }
}

/// @dev Recipient that attempts to re-enter `gimme()` from `receive()`.
contract TkGimmeReenterer {
    EthFaucet public faucet;

    constructor(address f) {
        faucet = EthFaucet(payable(f));
    }

    function claim() external returns (uint256) {
        return faucet.gimme();
    }

    receive() external payable {
        faucet.gimme();
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                 GIFTABLETOKEN
//////////////////////////////////////////////////////////////////////////////*/

contract AuditPoCGiftableToken is Test {
    GiftableToken impl;
    GiftableToken tok; // never expires (expiresAt == 0)

    address owner = makeAddr("gtOwner");
    address writer = makeAddr("gtWriter");
    address user1 = makeAddr("gtUser1");
    address user2 = makeAddr("gtUser2");
    address attacker = makeAddr("gtAttacker");

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        impl = new GiftableToken();
        tok = GiftableToken(LibClone.clone(address(impl)));
        tok.initialize("Voucher", "VCH", 6, owner, 0);
        vm.prank(owner);
        tok.addWriter(writer);
    }

    function _expiring(uint256 expiresAt) internal returns (GiftableToken t) {
        t = GiftableToken(LibClone.clone(address(impl)));
        t.initialize("Expiring", "EXP", 6, owner, expiresAt);
        vm.prank(owner);
        t.addWriter(writer);
    }

    function _assertNoSuchFunction(address target, string memory sig) internal {
        (bool ok,) = target.call(abi.encodeWithSignature(sig));
        assertFalse(ok, sig);
    }

    /*------------------------------------------------------------------
      FINDING: the `expired` flag / `Expired` event are NEVER persisted by
      the transfer path, because _beforeTokenTransfer reverts in the SAME
      call that flips the flag, rolling the SSTORE and the log back.
      SPEC claims "Expiry flips automatically on the first transfer at or
      after block.timestamp >= expiresAt".
    ------------------------------------------------------------------*/
    function test_GT_expiredFlagNeverPersistsViaTransferPath() public {
        uint256 t0 = block.timestamp + 1000;
        GiftableToken t = _expiring(t0);

        vm.prank(writer);
        t.mintTo(user1, 1000);

        vm.prank(user1);
        t.approve(user2, 500);

        vm.warp(t0);

        // The transfer reverts -- and takes `expired = true` + Expired() with it.
        vm.prank(user1);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.transfer(user2, 1);
        assertFalse(t.expired(), "expired should have flipped per SPEC; the SSTORE was reverted");

        vm.prank(user2);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.transferFrom(user1, user2, 1);
        assertFalse(t.expired());

        vm.prank(writer);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.mintTo(user2, 1);
        assertFalse(t.expired());

        // Only a standalone call can ever persist it.
        assertEq(t.applyExpiry(), 2);
        assertTrue(t.expired());
    }

    /// @dev Corollary: after arbitrarily many observed-expiry transfer attempts,
    ///      applyExpiry() still reports code 2 ("expiring right now") rather than
    ///      1 ("already expired"), so the Expired(timestamp) log an indexer would
    ///      consume is only ever produced out-of-band and carries the wrong
    ///      timestamp (when someone happened to call it, not the expiry time).
    function test_GT_expiryIsNeverRecordedByUsersHittingTheRevert() public {
        uint256 t0 = block.timestamp + 1000;
        GiftableToken t = _expiring(t0);
        vm.prank(writer);
        t.mintTo(user1, 1000);
        vm.warp(t0);

        for (uint256 i; i < 5; ++i) {
            vm.prank(user1);
            vm.expectRevert(GiftableToken.TokenExpired.selector);
            t.transfer(user2, 1);
            assertFalse(t.expired());
            skip(1 days);
        }

        // Whoever finally calls applyExpiry() stamps Expired() with *their*
        // timestamp, five days after the real expiry.
        assertEq(t.applyExpiry(), 2, "still 'expiring now', never 'already expired'");
        assertEq(block.timestamp, t0 + 5 days);
    }

    /*------------------------------------------------------------------
      FINDING: burn() is blocked after expiry. SPEC documents only that
      "every transfer (including mint) reverts", and documents burn purely
      in terms of InsufficientBalance. The owner can therefore never
      retire the supply of an expired token.
    ------------------------------------------------------------------*/
    function test_GT_burnRevertsAfterExpiry_supplyCanNeverBeRetired() public {
        uint256 t0 = block.timestamp + 1000;
        GiftableToken t = _expiring(t0);

        vm.prank(writer);
        t.mintTo(owner, 1000);

        vm.warp(t0);
        assertEq(t.applyExpiry(), 2);

        vm.prank(owner);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.burn(100);

        assertEq(t.totalSupply(), 1000);
        assertEq(t.totalBurned(), 0);

        // And it stays that way arbitrarily far in the future.
        vm.warp(t0 + 3650 days);
        vm.prank(owner);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.burn(1);
        assertEq(t.totalSupply(), 1000);
    }

    /// @dev Holder balances becoming permanently immovable at expiry IS the
    ///      documented intent ("Once expired, every transfer ... reverts").
    function test_GT_holderBalancesFrozenAtExpiry_matchesSpec_holds() public {
        uint256 t0 = block.timestamp + 1000;
        GiftableToken t = _expiring(t0);
        vm.prank(writer);
        t.mintTo(user1, 1000);
        vm.warp(t0);

        vm.prank(user1);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.transfer(user2, 1);
        assertEq(t.balanceOf(user1), 1000); // stuck, per SPEC
    }

    /*------------------------------------------------------------------
      FINDING: mintTo(address(0)) succeeds -> unrecoverable supply.
      solady's ERC20 explicitly declines to guard the zero address and
      tells integrators to "add any checks with overrides if desired".
      GiftableToken adds none.
    ------------------------------------------------------------------*/
    function test_GT_mintToZeroAddressInflatesSupplyIrrecoverably() public {
        vm.prank(writer);
        tok.mintTo(address(0), 1_000_000);

        assertEq(tok.balanceOf(address(0)), 1_000_000);
        assertEq(tok.totalSupply(), 1_000_000);
        assertEq(tok.totalMinted(), 1_000_000);
        assertEq(tok.totalBurned(), 0);

        // Nobody can ever move it: address(0) cannot sign and burn() only
        // burns from msg.sender.
        vm.prank(owner);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        tok.burn(1);
    }

    /*------------------------------------------------------------------
      FINDING: transfer(address(0)) destroys tokens without decreasing
      totalSupply and without incrementing totalBurned -> circulating
      supply is silently overstated.
    ------------------------------------------------------------------*/
    function test_GT_transferToZeroAddressSilentlyDestroysTokens() public {
        vm.prank(writer);
        tok.mintTo(user1, 1000);

        vm.prank(user1);
        assertTrue(tok.transfer(address(0), 400));

        assertEq(tok.balanceOf(user1), 600);
        assertEq(tok.balanceOf(address(0)), 400);
        assertEq(tok.totalSupply(), 1000, "totalSupply unchanged despite 400 destroyed");
        assertEq(tok.totalBurned(), 0, "totalBurned does not reflect the loss");
    }

    /*------------------------------------------------------------------
      FINDING: solady 0.1.26 grants the canonical Permit2 address an
      implicit, unrevocable infinite allowance over EVERY holder's balance.
      GiftableToken does not override _givePermit2InfiniteAllowance() and
      SPEC never mentions Permit2.
    ------------------------------------------------------------------*/
    function test_GT_permit2HasImplicitInfiniteAllowanceOverEveryHolder() public {
        vm.prank(writer);
        tok.mintTo(user1, 1000);

        // Nobody ever approved anything.
        assertEq(tok.allowance(user1, PERMIT2), type(uint256).max);
        assertEq(tok.allowance(user2, PERMIT2), type(uint256).max);
        assertEq(tok.allowance(address(0), PERMIT2), type(uint256).max);
    }

    function test_GT_permit2AddressCanDrainHoldersWithoutApproval() public {
        vm.prank(writer);
        tok.mintTo(user1, 1000);

        // Whatever code sits at the canonical Permit2 address on the target
        // chain can move any holder's balance with zero on-chain approval.
        vm.prank(PERMIT2);
        tok.transferFrom(user1, attacker, 1000);

        assertEq(tok.balanceOf(attacker), 1000);
        assertEq(tok.balanceOf(user1), 0);
        assertEq(tok.allowance(user1, PERMIT2), type(uint256).max, "not even decremented");
    }

    /// @dev ERC20 conformance break: approve() reverts for a legitimate spender,
    ///      and the implicit allowance cannot be revoked.
    function test_GT_approveRevertsForPermit2AndCannotBeRevoked() public {
        vm.prank(user1);
        vm.expectRevert(ERC20.Permit2AllowanceIsFixedAtInfinity.selector);
        tok.approve(PERMIT2, 100);

        vm.prank(user1);
        vm.expectRevert(ERC20.Permit2AllowanceIsFixedAtInfinity.selector);
        tok.approve(PERMIT2, 0);
    }

    /*------------------------------------------------------------------
      FINDING: the expiry timestamp is private with no getter, so clients
      and integrating contracts cannot read when the token expires --
      while supportsInterface() advertises seven interface ids.
    ------------------------------------------------------------------*/
    function test_GT_expiryTimestampHasNoOnChainGetter() public {
        GiftableToken t = _expiring(block.timestamp + 1000);
        _assertNoSuchFunction(address(t), "expires()");
        _assertNoSuchFunction(address(t), "expiresAt()");
        _assertNoSuchFunction(address(t), "expiry()");
        _assertNoSuchFunction(address(t), "expireTimestamp()");
        _assertNoSuchFunction(address(t), "expirationTimestamp()");

        // All seven advertised ids answer true regardless.
        assertTrue(t.supportsInterface(0x01ffc9a7));
        assertTrue(t.supportsInterface(0xb61bc941));
        assertTrue(t.supportsInterface(0x449a52f8));
        assertTrue(t.supportsInterface(0x9493f8b2));
        assertTrue(t.supportsInterface(0xabe1f1f5));
        assertTrue(t.supportsInterface(0xb1110c1b));
        assertTrue(t.supportsInterface(0x841a0e94));
    }

    /*------------------------------------------------------------------
      L-7 (FIXED): a token cannot consume its initializer with a zero owner.
    ------------------------------------------------------------------*/
    function test_GT_initializeRejectsZeroOwner() public {
        GiftableToken t = GiftableToken(LibClone.clone(address(impl)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        t.initialize("Orphan", "ORP", 6, address(0), 0);
    }

    /*------------------------------------------------------------------
      FINDING: initialize() accepts an expiresAt already in the past,
      producing a token that is dead on arrival.
    ------------------------------------------------------------------*/
    function test_GT_initializeAcceptsPastExpiryProducingDeadToken() public {
        vm.warp(1_000_000);
        GiftableToken t = GiftableToken(LibClone.clone(address(impl)));
        t.initialize("Past", "PST", 6, owner, 1); // expired at epoch+1

        vm.prank(owner);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        t.mintTo(user1, 1);

        assertEq(t.totalSupply(), 0);
        assertEq(t.applyExpiry(), 2);
    }

    /*------------------------------------------------------------------
      PROPERTIES THAT HOLD
    ------------------------------------------------------------------*/

    function test_GT_mintBurnAccountingInvariant_holds() public {
        vm.startPrank(writer);
        tok.mintTo(owner, 1000);
        tok.mintTo(user1, 2500);
        vm.stopPrank();

        vm.prank(owner);
        tok.burn(400);

        assertEq(tok.totalMinted(), 3500);
        assertEq(tok.totalBurned(), 400);
        assertEq(tok.totalSupply(), 3100);
        assertEq(tok.totalMinted() - tok.totalBurned(), tok.totalSupply());
    }

    function test_GT_totalMintedOverflowReverts_holds() public {
        vm.prank(writer);
        tok.mintTo(user1, type(uint256).max);
        vm.prank(writer);
        vm.expectRevert(stdError.arithmeticError); // `totalMinted += amount_`
        tok.mintTo(user2, 1);
    }

    function test_GT_burnCannotUnderflow_holds() public {
        vm.prank(writer);
        tok.mintTo(owner, 100);
        vm.prank(owner);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        tok.burn(101);
        assertEq(tok.totalBurned(), 0);
        assertEq(tok.totalSupply(), 100);
    }

    function test_GT_applyExpiryIsIdempotentAndPermissionless_holds() public {
        uint256 t0 = block.timestamp + 1000;
        GiftableToken t = _expiring(t0);

        vm.prank(attacker);
        assertEq(t.applyExpiry(), 0);
        assertFalse(t.expired());

        vm.warp(t0);
        vm.prank(attacker);
        assertEq(t.applyExpiry(), 2);
        vm.prank(attacker);
        assertEq(t.applyExpiry(), 1);
        vm.prank(attacker);
        assertEq(t.applyExpiry(), 1);
        assertTrue(t.expired());
    }

    /// @dev expiresAt == 0 is handled on every path.
    function test_GT_zeroExpiryNeverExpires_holds() public {
        assertEq(tok.applyExpiry(), 0);
        vm.warp(block.timestamp + 3650 days);
        assertEq(tok.applyExpiry(), 0);
        assertFalse(tok.expired());

        vm.prank(writer);
        tok.mintTo(user1, 100);
        vm.prank(user1);
        assertTrue(tok.transfer(user2, 50));
        vm.prank(owner);
        tok.mintTo(owner, 10);
        vm.prank(owner);
        tok.burn(10);
        assertEq(tok.totalBurned(), 10);
    }

    function test_GT_isWriterMatchesOnlyWriterModifier_holds() public {
        assertTrue(tok.isWriter(owner));
        assertTrue(tok.isWriter(writer));
        assertFalse(tok.isWriter(user1));

        vm.prank(owner);
        tok.mintTo(user1, 1); // owner passes onlyWriter
        vm.prank(writer);
        tok.mintTo(user1, 1);
        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        tok.mintTo(user1, 1);

        vm.prank(owner);
        tok.deleteWriter(writer);
        assertFalse(tok.isWriter(writer));
        vm.prank(writer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        tok.mintTo(user1, 1);
    }

    function test_GT_erc20BasicsConform_holds() public {
        vm.prank(writer);
        tok.mintTo(user1, 1000);

        vm.prank(user1);
        assertTrue(tok.transfer(user2, 100));
        vm.prank(user1);
        assertTrue(tok.approve(user2, 500));
        vm.prank(user2);
        assertTrue(tok.transferFrom(user1, user2, 200));
        assertEq(tok.allowance(user1, user2), 300);

        // self transfer is a no-op on balance
        vm.prank(user1);
        tok.transfer(user1, 50);
        assertEq(tok.balanceOf(user1), 700);

        // zero-value transfer allowed
        vm.prank(user1);
        assertTrue(tok.transfer(user2, 0));

        // over-spending allowance reverts
        vm.prank(user2);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        tok.transferFrom(user1, user2, 301);
    }

    /// @dev Infinite allowance is not decremented (standard convention).
    function test_GT_infiniteAllowanceNotDecremented_holds() public {
        vm.prank(writer);
        tok.mintTo(user1, 1000);
        vm.prank(user1);
        tok.approve(user2, type(uint256).max);
        vm.prank(user2);
        tok.transferFrom(user1, user2, 400);
        assertEq(tok.allowance(user1, user2), type(uint256).max);
    }

    /// @dev EIP-2612 permit binds chainid + address(this) + a monotonic nonce,
    ///      so there is no cross-chain / cross-clone / replay path.
    function test_GT_permitDomainSeparatorAndNonceAreSound_holds() public {
        (address signer, uint256 pk) = makeAddrAndKey("gtPermitSigner");
        vm.prank(writer);
        tok.mintTo(signer, 1000);

        bytes32 ds = tok.DOMAIN_SEPARATOR();
        assertEq(tok.nonces(signer), 0);

        uint256 deadline = block.timestamp + 1;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                user2,
                uint256(500),
                uint256(0),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        tok.permit(signer, user2, 500, deadline, v, r, s);
        assertEq(tok.allowance(signer, user2), 500);
        assertEq(tok.nonces(signer), 1);

        // replay fails (nonce consumed)
        vm.expectRevert(ERC20.InvalidPermit.selector);
        tok.permit(signer, user2, 500, deadline, v, r, s);

        // domain separator is chain-bound
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        assertTrue(tok.DOMAIN_SEPARATOR() != ds);
        vm.chainId(chain);

        // ... and instance-bound: an identically-named clone rejects the sig.
        GiftableToken sibling = GiftableToken(LibClone.clone(address(impl)));
        sibling.initialize("Voucher", "VCH", 6, owner, 0);
        assertTrue(sibling.DOMAIN_SEPARATOR() != ds);
        vm.expectRevert(ERC20.InvalidPermit.selector);
        sibling.permit(signer, user2, 500, deadline, v, r, s);
    }

    /// @dev Documented: a writer can mint without bound.
    function test_GT_writerCanMintWithoutBound_matchesSpec_holds() public {
        vm.prank(writer);
        tok.mintTo(attacker, type(uint128).max);
        assertEq(tok.balanceOf(attacker), type(uint128).max);
        assertEq(tok.totalMinted(), type(uint128).max);
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                   ETHFAUCET
//////////////////////////////////////////////////////////////////////////////*/

contract AuditPoCEthFaucet is Test {
    EthFaucet impl;
    EthFaucet faucet;
    PeriodSimple periodImpl;
    PeriodSimple period;
    TkRegistry registry;

    address owner = makeAddr("efOwner");
    address user1 = makeAddr("efUser1");
    address user2 = makeAddr("efUser2");
    address attacker = makeAddr("efAttacker");

    function setUp() public {
        impl = new EthFaucet();
        faucet = EthFaucet(payable(LibClone.clone(address(impl))));
        faucet.initialize(owner, 1 ether);

        periodImpl = new PeriodSimple();
        period = PeriodSimple(LibClone.clone(address(periodImpl)));
        period.initialize(owner, address(faucet));

        registry = new TkRegistry();
    }

    /// Both gates now fail closed, so a test that is not about the registry
    /// still has to supply one that admits everybody it uses.
    function _openRegistry() internal {
        TkOpenRegistry open = new TkOpenRegistry();
        vm.prank(owner);
        faucet.setRegistry(address(open));
    }

    function _openPeriod() internal {
        vm.prank(owner);
        faucet.setPeriodChecker(address(period));
    }

    function _openGating() internal {
        _openRegistry();
        _openPeriod();
    }

    /*==================================================================
      PRIORITY: re-verify the stale scv-scan.md Finding 1 claim.
      `seal()` IS `onlyOwner` in the current code => NOT PRESENT.
    ==================================================================*/
    function test_EF_sealIsOwnerGated_staleFindingNotPresent_isCorrect() public {
        _openGating();

        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.seal(1);

        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.seal(7);

        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.seal(0);

        assertEq(faucet.sealState(), 0, "no unprivileged caller could lock any field");

        // Owner still can.
        vm.prank(owner);
        assertEq(faucet.seal(7), 7);
    }

    function test_EF_everyStateChangingSetterIsOwnerGated_isCorrect() public {
        vm.startPrank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.setAmount(123);
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.setRegistry(address(registry));
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.setPeriodChecker(address(period));
        vm.expectRevert(Ownable.Unauthorized.selector);
        faucet.seal(1);
        vm.stopPrank();

        assertEq(faucet.amount(), 1 ether);
        assertEq(faucet.registry(), address(0));
        assertEq(faucet.periodChecker(), address(0));
        assertEq(faucet.sealState(), 0);
    }

    /*------------------------------------------------------------------
      H-5 (FIXED): seal() requires the field to hold a meaningful value
      before its bit can be locked, so an operator hardening a fresh
      deployment can no longer freeze the gating in its disabled state.
    ------------------------------------------------------------------*/
    function test_EF_sealingUnsetGatingIsRejected() public {
        assertEq(faucet.registry(), address(0));
        assertEq(faucet.periodChecker(), address(0));

        vm.startPrank(owner);
        vm.expectRevert(EthFaucet.InvalidState.selector);
        faucet.seal(3); // REGISTRY_STATE | PERIODCHECKER_STATE
        vm.expectRevert(EthFaucet.InvalidState.selector);
        faucet.seal(1);
        vm.expectRevert(EthFaucet.InvalidState.selector);
        faucet.seal(2);
        vm.stopPrank();

        assertEq(faucet.sealState(), 0, "nothing was locked");

        // Configuring first, then sealing, is still allowed.
        _openGating();
        vm.prank(owner);
        assertEq(faucet.seal(3), 3);
        assertTrue(faucet.registry() != address(0));
        assertTrue(faucet.periodChecker() != address(0));
    }

    /*------------------------------------------------------------------
      H-4 (FIXED): the gates fail CLOSED. Straight after initialize()
      both registry and periodChecker are address(0), and every claim
      path reverts rather than dispensing without a rate limit.
    ------------------------------------------------------------------*/
    function test_EF_defaultConfigServesNobody() public {
        vm.deal(address(faucet), 10 ether);
        assertFalse(faucet.check(user1), "check() reports the faucet as unusable");

        vm.prank(user1);
        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.gimme();

        vm.prank(attacker);
        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.giveTo(attacker);

        assertEq(user1.balance, 0);
        assertEq(address(faucet).balance, 10 ether, "nothing left the faucet");
    }

    /// @dev A whitelist alone is not enough either: the cooldown gate has to
    ///      be configured before anything is served.
    function test_EF_registryWithoutPeriodCheckerStillServesNobody() public {
        _openRegistry();
        vm.deal(address(faucet), 10 ether);

        assertFalse(faucet.check(user1));
        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();
        assertEq(address(faucet).balance, 10 ether);
    }

    /// @dev The owner can no longer *re*-open a gated faucet by setting either
    ///      address back to zero.
    function test_EF_settingGatingBackToZeroIsRejected() public {
        vm.startPrank(owner);
        faucet.setRegistry(address(registry));
        faucet.setPeriodChecker(address(period));
        period.setPeriod(1 days);
        vm.stopPrank();

        vm.deal(address(faucet), 5 ether);
        vm.prank(user1);
        vm.expectRevert(EthFaucet.NotInWhitelist.selector);
        faucet.gimme();

        vm.startPrank(owner);
        vm.expectRevert(EthFaucet.InvalidAddress.selector);
        faucet.setRegistry(address(0));
        vm.expectRevert(EthFaucet.InvalidAddress.selector);
        faucet.setPeriodChecker(address(0));
        vm.stopPrank();

        assertEq(faucet.registry(), address(registry), "gating intact");
        assertEq(faucet.periodChecker(), address(period));

        vm.prank(user1);
        vm.expectRevert(EthFaucet.NotInWhitelist.selector);
        faucet.gimme();
        assertEq(user1.balance, 0);
    }

    /*------------------------------------------------------------------
      FINDING: `giveTo` is permissionless and the cooldown is keyed by
      RECIPIENT, not by caller. A single actor drains the entire balance
      in one transaction using fresh addresses, even with a 1-day
      PeriodSimple and a balanceThreshold configured.
    ------------------------------------------------------------------*/
    function test_EF_giveToRecipientRotationDrainsFaucetDespiteCooldown() public {
        _openRegistry();
        vm.startPrank(owner);
        faucet.setPeriodChecker(address(period));
        period.setPeriod(1 days);
        period.setBalanceThreshold(0.5 ether); // does not help: sybils start at 0
        vm.stopPrank();

        vm.deal(address(faucet), 10 ether);

        address[] memory sybils = new address[](10);
        vm.startPrank(attacker);
        for (uint256 i; i < 10; ++i) {
            sybils[i] = address(uint160(0xBEEF0000 + i));
            faucet.giveTo(sybils[i]);
        }
        vm.stopPrank();

        assertEq(address(faucet).balance, 0, "entire faucet drained in one tx");
        for (uint256 i; i < 10; ++i) {
            assertEq(sybils[i].balance, 1 ether);
        }

        // The per-address cooldown itself works -- it just protects nothing.
        vm.deal(address(faucet), 1 ether);
        vm.prank(attacker);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.giveTo(sybils[0]);
    }

    /*------------------------------------------------------------------
      M-16 (FIXED): owner recovery remains available after sealing, so an
      unusable configuration and sub-claim dust cannot strand ETH.
    ------------------------------------------------------------------*/
    function test_EF_ownerCanRecoverEthAfterAmountIsSealed() public {
        _openGating();
        vm.deal(address(faucet), 0.5 ether); // < amount (1 ether)

        vm.prank(owner);
        faucet.seal(4); // VALUE_STATE

        vm.prank(owner);
        vm.expectRevert(EthFaucet.Sealed.selector);
        faucet.setAmount(0.5 ether);

        vm.prank(user1);
        vm.expectRevert(EthFaucet.InsufficientBalance.selector);
        faucet.gimme();

        vm.prank(owner);
        assertEq(faucet.withdraw(payable(owner), 0.5 ether), 0.5 ether);
        assertEq(address(faucet).balance, 0);
        assertEq(owner.balance, 0.5 ether);
    }

    /// @dev Residual balance below the claim amount is recoverable by the owner.
    function test_EF_dustBelowAmountIsRecoverable() public {
        _openGating();
        vm.deal(address(faucet), 1.5 ether);
        vm.prank(user1);
        faucet.gimme();
        assertEq(address(faucet).balance, 0.5 ether);
        vm.prank(user2);
        vm.expectRevert(EthFaucet.InsufficientBalance.selector);
        faucet.gimme();
        assertFalse(faucet.check(user2));
        vm.prank(owner);
        faucet.withdraw(payable(owner), 0.5 ether);
        assertEq(address(faucet).balance, 0);
    }

    /*------------------------------------------------------------------
      M-18 (FIXED): malformed backend replies fail with the dedicated
      RegistryBackend / PeriodBackend errors instead of an array panic or
      permissive one-byte interpretation.
    ------------------------------------------------------------------*/
    function test_EF_registryWithNoCodeRevertsRegistryBackend() public {
        _openPeriod();
        address eoaRegistry = makeAddr("efEoaRegistry");
        assertEq(eoaRegistry.code.length, 0);

        vm.prank(owner);
        faucet.setRegistry(eoaRegistry);
        vm.deal(address(faucet), 10 ether);

        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.check(user1);

        vm.prank(user1);
        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.gimme();
    }

    function test_EF_periodCheckerWithNoCodeRevertsPeriodBackend() public {
        _openRegistry();
        address eoaChecker = makeAddr("efEoaChecker");
        vm.prank(owner);
        faucet.setPeriodChecker(eoaChecker);
        vm.deal(address(faucet), 10 ether);

        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.check(user1);

        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme(); // poke() returns empty data and is rejected explicitly
    }

    function test_EF_registryReturningShortDataRevertsRegistryBackend() public {
        _openPeriod();
        TkShortReturnRegistry short = new TkShortReturnRegistry();
        vm.prank(owner);
        faucet.setRegistry(address(short));
        vm.deal(address(faucet), 10 ether);

        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.check(user1);
    }

    function test_EF_registryRejectsNonCanonicalBool() public {
        _openPeriod();
        vm.deal(address(faucet), 10 ether);

        TkNonCanonicalBoolRegistry lax = new TkNonCanonicalBoolRegistry(257);
        vm.prank(owner);
        faucet.setRegistry(address(lax));
        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.check(user1);

        TkNonCanonicalBoolRegistry weird = new TkNonCanonicalBoolRegistry(256);
        vm.prank(owner);
        faucet.setRegistry(address(weird));
        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.check(user2);
        vm.prank(user2);
        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        faucet.gimme();
    }

    /*------------------------------------------------------------------
      L-24 (FIXED): missing or short numeric replies use the dedicated
      PeriodBackendError rather than bubbling an ABI decode failure.
    ------------------------------------------------------------------*/
    function test_EF_nextTimeWithUnsetPeriodCheckerRevertsDedicatedError() public {
        assertEq(faucet.periodChecker(), address(0));
        (bool ok, bytes memory ret) = address(0).call(abi.encodeWithSignature("next(address)", user1));
        assertTrue(ok, "call to address(0) succeeds");
        assertEq(ret.length, 0, "with empty returndata");

        vm.expectRevert(EthFaucet.PeriodBackendError.selector);
        faucet.nextTime(user1);
    }

    /*------------------------------------------------------------------
      FINDING: nextBalance() encodes a stray argument into the zero-arg
      selector `balanceThreshold()` and returns a global value, so its
      `_subject` parameter is meaningless.
    ------------------------------------------------------------------*/
    function test_EF_nextBalanceIgnoresItsSubjectArgument() public {
        _openPeriod();
        vm.prank(owner);
        period.setBalanceThreshold(3 ether);

        assertEq(faucet.nextBalance(user1), 3 ether);
        assertEq(faucet.nextBalance(user2), 3 ether);
        assertEq(faucet.nextBalance(address(0)), 3 ether);
    }

    /*------------------------------------------------------------------
      FINDING: amount == 0 still consumes the recipient's cooldown, so
      anyone can burn a victim's claim slot for free via giveTo().
    ------------------------------------------------------------------*/
    function test_EF_zeroAmountClaimBurnsVictimCooldownForFree() public {
        _openRegistry();
        vm.startPrank(owner);
        faucet.setPeriodChecker(address(period));
        faucet.setAmount(0);
        period.setPeriod(1 days);
        vm.stopPrank();

        vm.deal(address(faucet), 10 ether);

        // Attacker "gives" nothing to the victim.
        vm.prank(attacker);
        assertEq(faucet.giveTo(user1), 0);
        assertEq(user1.balance, 0);
        assertEq(period.lastUsed(user1), block.timestamp);

        // Owner restores a real amount; the victim must now wait a full day.
        vm.prank(owner);
        faucet.setAmount(1 ether);
        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();
    }

    /*------------------------------------------------------------------
      PROPERTIES THAT HOLD
    ------------------------------------------------------------------*/

    /// @dev poke() is invoked BEFORE the payout (checks-effects-interactions).
    function test_EF_pokeHappensBeforePayout_isCorrect() public {
        _openRegistry();
        TkOrderPeriodChecker probe = new TkOrderPeriodChecker();
        probe.setFaucet(address(faucet));
        vm.prank(owner);
        faucet.setPeriodChecker(address(probe));

        vm.deal(address(faucet), 10 ether);
        vm.prank(user1);
        faucet.gimme();

        assertTrue(probe.pokeCalled());
        assertEq(probe.faucetBalanceAtPoke(), 10 ether, "payout had not yet happened at poke time");
        assertEq(address(faucet).balance, 9 ether);
    }

    /// @dev poke()'s return value IS checked; a refusing checker blocks the claim.
    function test_EF_pokeReturnValueIsChecked_isCorrect() public {
        _openRegistry();
        TkRefusingPeriodChecker refuse = new TkRefusingPeriodChecker();
        vm.prank(owner);
        faucet.setPeriodChecker(address(refuse));
        vm.deal(address(faucet), 10 ether);

        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();

        vm.prank(attacker);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.giveTo(user1);

        assertEq(address(faucet).balance, 10 ether);
        assertFalse(faucet.check(user1));
    }

    /// @dev The 2300-gas stipend makes reentrancy from the recipient impossible.
    function test_EF_recipientCannotReenterThroughTransferStipend_isCorrect() public {
        _openGating();
        TkGimmeReenterer r = new TkGimmeReenterer(address(faucet));
        vm.deal(address(faucet), 10 ether);

        vm.expectRevert(); // transfer() fails: receive() ran out of the stipend
        r.claim();

        assertEq(address(faucet).balance, 10 ether);
        assertEq(address(r).balance, 0);
    }

    /// @dev A malicious registry gets full gas and CAN re-enter, but the
    ///      revert-on-failure `transfer` prevents any over-draw.
    function test_EF_maliciousRegistryReentrancyCannotOverdraw_isCorrect() public {
        _openPeriod();
        TkReentrantRegistry evil = new TkReentrantRegistry();
        evil.arm(address(faucet), user2);
        vm.prank(owner);
        faucet.setRegistry(address(evil));

        // Only enough for a single payout: the nested claim takes it, the outer
        // transfer then fails and the whole transaction unwinds.
        vm.deal(address(faucet), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        faucet.giveTo(user1);
        assertEq(address(faucet).balance, 1 ether);
        assertEq(user1.balance, 0);
        assertEq(user2.balance, 0);

        // With funds for both, both are paid -- i.e. no more than the balance.
        evil.arm(address(faucet), user2);
        vm.deal(address(faucet), 2 ether);
        vm.prank(attacker);
        faucet.giveTo(user1);
        assertEq(user1.balance, 1 ether);
        assertEq(user2.balance, 1 ether);
        assertEq(address(faucet).balance, 0);
    }

    /// @dev Documented in SPEC: contract recipients with a costly receive fail.
    function test_EF_costlyContractRecipientCannotBeFunded_matchesSpec_holds() public {
        _openGating();
        TkCostlyReceiver c = new TkCostlyReceiver();
        vm.deal(address(faucet), 10 ether);

        vm.prank(attacker);
        vm.expectRevert();
        faucet.giveTo(address(c));
        assertEq(address(c).balance, 0);
    }

    /// @dev Balance is checked before payout, so `transfer` never fails for
    ///      insufficient funds.
    function test_EF_balanceCheckedBeforePayout_isCorrect() public {
        _openGating();
        vm.deal(address(faucet), 1 ether);
        vm.prank(user1);
        faucet.gimme();
        assertEq(address(faucet).balance, 0);
        vm.prank(user2);
        vm.expectRevert(EthFaucet.InsufficientBalance.selector);
        faucet.gimme();
    }

    /// @dev Seal bits are additive and cannot be cleared.
    function test_EF_sealBitsAreMonotonic_isCorrect() public {
        _openGating();

        vm.startPrank(owner);
        faucet.seal(1);
        vm.expectRevert(EthFaucet.AlreadyLocked.selector);
        faucet.seal(1);
        vm.expectRevert(EthFaucet.AlreadyLocked.selector);
        faucet.seal(3); // overlaps bit 1
        faucet.seal(2);
        faucet.seal(4);
        assertEq(faucet.sealState(), 7);
        vm.expectRevert(EthFaucet.InvalidState.selector);
        faucet.seal(8);
        vm.stopPrank();
    }

    /// @dev If PeriodSimple's poker is not the faucet, claims fail CLOSED.
    function test_EF_misconfiguredPokerFailsClosed_isCorrect() public {
        _openRegistry();
        PeriodSimple p2 = PeriodSimple(LibClone.clone(address(periodImpl)));
        p2.initialize(owner, makeAddr("efWrongPoker"));
        vm.prank(owner);
        faucet.setPeriodChecker(address(p2));
        vm.deal(address(faucet), 10 ether);

        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();
        assertEq(address(faucet).balance, 10 ether);
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                  PERIODSIMPLE
//////////////////////////////////////////////////////////////////////////////*/

contract AuditPoCPeriodSimple is Test {
    PeriodSimple impl;
    PeriodSimple period;
    EthFaucet faucetImpl;
    EthFaucet faucet;

    address owner = makeAddr("psOwner");
    address poker = makeAddr("psPoker");
    address user1 = makeAddr("psUser1");
    address user2 = makeAddr("psUser2");
    address attacker = makeAddr("psAttacker");

    function setUp() public {
        vm.warp(1_700_000_000);
        impl = new PeriodSimple();
        period = PeriodSimple(LibClone.clone(address(impl)));
        period.initialize(owner, poker);

        faucetImpl = new EthFaucet();
        faucet = EthFaucet(payable(LibClone.clone(address(faucetImpl))));
        faucet.initialize(owner, 1 ether);
    }

    /// @dev Replaces `period` with an instance whose poker is the faucet, and
    ///      wires it in.
    function _wireFaucet() internal {
        PeriodSimple p = PeriodSimple(LibClone.clone(address(impl)));
        p.initialize(owner, address(faucet));
        TkOpenRegistry open = new TkOpenRegistry();
        vm.startPrank(owner);
        faucet.setPeriodChecker(address(p));
        faucet.setRegistry(address(open));
        vm.stopPrank();
        period = p;
    }

    /*------------------------------------------------------------------
      FINDING: setPeriod() is unbounded. A period near 2**256 makes
      `lastUsed + period` overflow inside next(), which have() reaches via
      an external self-call, so have()/poke()/next() all REVERT for every
      subject that has ever claimed -- bricking the faucet for them.
      Never-poked subjects are unaffected (they return early), so the
      failure is silent and selective.
    ------------------------------------------------------------------*/
    function test_PS_unboundedPeriodOverflowBricksPreviouslyPokedSubjects() public {
        _wireFaucet();
        vm.deal(address(faucet), 100 ether);

        vm.prank(user1);
        faucet.gimme(); // user1 now has lastUsed != 0
        assertTrue(period.lastUsed(user1) > 0);

        vm.prank(owner);
        period.setPeriod(type(uint256).max);

        vm.expectRevert(stdError.arithmeticError);
        period.next(user1);
        vm.expectRevert(stdError.arithmeticError);
        period.have(user1);

        // The faucet inherits the DoS -- even check(), which must return bool.
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.check(user1);
        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();

        // A never-poked address still works: the breakage is invisible until a
        // returning user complains.
        assertTrue(period.have(user2));
        vm.prank(user2);
        faucet.gimme();
        assertEq(user2.balance, 1 ether);
    }

    /*------------------------------------------------------------------
      FINDING: the owner / poker can consume a subject's cooldown without
      any payout, and there is no way to reset lastUsed.
    ------------------------------------------------------------------*/
    function test_PS_pokerCanBurnSubjectCooldownWithNoPayoutAndNoReset() public {
        _wireFaucet();
        vm.prank(owner);
        period.setPeriod(30 days);
        vm.deal(address(faucet), 100 ether);

        assertTrue(period.have(user1));

        // Owner (or the poker key) pokes the victim directly.
        vm.prank(owner);
        assertTrue(period.poke(user1));
        assertEq(period.lastUsed(user1), block.timestamp);
        assertEq(user1.balance, 0, "no ETH was paid");

        // Victim is locked out for 30 days.
        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();

        // And nothing can undo it.
        _assertNoSuchFunction("resetLastUsed(address)");
        _assertNoSuchFunction("unpoke(address)");
        _assertNoSuchFunction("clearLastUsed(address)");
        (bool ok,) = address(period).call(abi.encodeWithSignature("setLastUsed(address,uint256)", user1, uint256(0)));
        assertFalse(ok);
        assertEq(period.lastUsed(user1), block.timestamp);
    }

    function _assertNoSuchFunction(string memory sig) internal {
        vm.prank(owner);
        (bool ok,) = address(period).call(abi.encodeWithSignature(sig, user1));
        assertFalse(ok, sig);
    }

    /*------------------------------------------------------------------
      FINDING: next() for a never-poked subject returns `period` (an
      absolute timestamp of `0 + period`), which contradicts have().
      With a large period, clients are told a brand-new user must wait
      while have() says they are eligible now.
    ------------------------------------------------------------------*/
    function test_PS_nextContradictsHaveForNeverPokedSubject() public {
        vm.prank(owner);
        period.setPeriod(2_000_000_000); // an absolute time in the future

        assertEq(period.lastUsed(user1), 0);
        assertTrue(period.have(user1), "eligible");
        assertEq(period.next(user1), 2_000_000_000);
        assertTrue(period.next(user1) > block.timestamp, "but next() says: wait");

        // The same contradiction surfaces through the faucet's public API.
        vm.prank(owner);
        faucet.setPeriodChecker(address(period));
        assertEq(faucet.nextTime(user1), 2_000_000_000);
    }

    /*------------------------------------------------------------------
      FINDING: period == 0 is accepted and yields a 1-second cooldown
      rather than "no limit" -- an easy footgun for the default
      (uninitialized) value.
    ------------------------------------------------------------------*/
    function test_PS_zeroPeriodYieldsOneSecondCooldown() public {
        assertEq(period.period(), 0); // default after initialize()

        vm.prank(owner);
        assertTrue(period.poke(user1));
        assertFalse(period.have(user1)); // same second: blocked
        skip(1);
        assertTrue(period.have(user1)); // next second: eligible again
        vm.prank(owner);
        assertTrue(period.poke(user1));
    }

    /*------------------------------------------------------------------
      PROPERTIES THAT HOLD
    ------------------------------------------------------------------*/

    /// @dev SPEC order: balanceThreshold is evaluated FIRST and overrides
    ///      first-time eligibility.
    function test_PS_balanceThresholdOverridesFirstTimeEligibility_matchesSpec_holds() public {
        vm.prank(owner);
        period.setBalanceThreshold(1 ether);

        // Never poked, but rich -> ineligible (threshold wins over lastUsed==0).
        assertEq(period.lastUsed(user1), 0);
        vm.deal(user1, 1 ether); // >= threshold
        assertFalse(period.have(user1));

        vm.prank(owner);
        assertFalse(period.poke(user1));
        assertEq(period.lastUsed(user1), 0, "poke must not record when ineligible");

        // Just below the threshold -> eligible.
        vm.deal(user1, 1 ether - 1);
        assertTrue(period.have(user1));

        // Threshold 0 disables the check entirely, even for huge balances.
        vm.prank(owner);
        period.setBalanceThreshold(0);
        vm.deal(user1, 1_000_000 ether);
        assertTrue(period.have(user1));
    }

    /// @dev No ordering lets a subject claim twice inside one period.
    function test_PS_noDoubleClaimWithinPeriod_isCorrect() public {
        _wireFaucet();
        vm.prank(owner);
        period.setPeriod(1 days);
        vm.deal(address(faucet), 100 ether);

        vm.prank(user1);
        faucet.gimme();

        // same block
        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();
        // via giveTo (different caller, same recipient)
        vm.prank(attacker);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.giveTo(user1);
        // exactly at the boundary
        skip(1 days);
        vm.prank(user1);
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        faucet.gimme();
        // boundary + 1
        skip(1);
        vm.prank(user1);
        faucet.gimme();
        assertEq(user1.balance, 2 ether);
    }

    /// @dev `>` (not `>=`) makes the effective wait period+1 seconds; SPEC
    ///      documents exactly this comparison.
    function test_PS_strictBoundaryMatchesSpec_holds() public {
        vm.prank(owner);
        period.setPeriod(3600);
        uint256 t = block.timestamp;
        vm.prank(owner);
        period.poke(user1);

        vm.warp(t + 3600);
        assertEq(period.next(user1), t + 3600);
        assertFalse(period.have(user1));
        vm.warp(t + 3601);
        assertTrue(period.have(user1));
    }

    function test_PS_pokeAccessControl_isCorrect() public {
        vm.prank(attacker);
        vm.expectRevert(PeriodSimple.Access.selector);
        period.poke(user1);

        vm.prank(address(faucet)); // not the poker of this instance
        vm.expectRevert(PeriodSimple.Access.selector);
        period.poke(user1);

        vm.prank(poker);
        assertTrue(period.poke(user1));
        vm.prank(owner);
        assertTrue(period.poke(user2));
    }

    function test_PS_configSettersAreOwnerOnly_isCorrect() public {
        vm.startPrank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        period.setPeriod(1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        period.setPoker(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        period.setBalanceThreshold(1);
        vm.stopPrank();

        // The poker itself cannot escalate to config.
        vm.prank(poker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        period.setPoker(attacker);
    }

    function test_PS_lastUsedIsPerSubject_isCorrect() public {
        vm.prank(owner);
        period.setPeriod(1 days);
        vm.prank(owner);
        period.poke(user1);
        assertFalse(period.have(user1));
        assertTrue(period.have(user2));
        assertEq(period.lastUsed(user2), 0);
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                      CAT
//////////////////////////////////////////////////////////////////////////////*/

contract AuditPoCCat is Test {
    CAT impl;
    CAT cat;

    address owner = makeAddr("catOwner");
    address writer = makeAddr("catWriter");
    address user1 = makeAddr("catUser1");
    address user2 = makeAddr("catUser2");
    address attacker = makeAddr("catAttacker");

    address[5] tokens5;

    event TokensSet(address indexed account, address[] tokens);

    function setUp() public {
        impl = new CAT();
        cat = CAT(LibClone.clone(address(impl)));
        cat.initialize(owner);
        vm.prank(owner);
        cat.addWriter(writer);

        for (uint256 i; i < 5; ++i) {
            tokens5[i] = address(uint160(0xA0A00000 + i));
        }
    }

    function _list(uint256 n) internal view returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tokens5[i];
        }
    }

    function _assertNoSuchFunction(string memory sig) internal {
        (bool ok,) = address(cat).call(abi.encodeWithSignature(sig, user1));
        assertFalse(ok, sig);
    }

    /*------------------------------------------------------------------
      PROPERTY THAT HOLDS: shrinking 5 -> 2 fully clears the tail.
      Verified at the raw-storage level, not just through the getters.
    ------------------------------------------------------------------*/
    function test_CAT_shrinkingFromFiveToTwoClearsStorageTail_isCorrect() public {
        vm.prank(user1);
        cat.setTokens(_list(5));
        assertEq(cat.tokenCount(user1), 5);

        // `_tokens` is the first declared state variable => slot 0.
        bytes32 lenSlot = keccak256(abi.encode(user1, uint256(0)));
        bytes32 dataStart = keccak256(abi.encode(lenSlot));
        assertEq(uint256(vm.load(address(cat), lenSlot)), 5, "slot 0 assumption");
        for (uint256 i; i < 5; ++i) {
            assertEq(address(uint160(uint256(vm.load(address(cat), bytes32(uint256(dataStart) + i))))), tokens5[i]);
        }

        vm.prank(user1);
        cat.setTokens(_list(2));

        assertEq(cat.tokenCount(user1), 2);
        assertEq(cat.getTokens(user1).length, 2);
        assertEq(cat.tokenAt(user1, 0), tokens5[0]);
        assertEq(cat.tokenAt(user1, 1), tokens5[1]);

        vm.expectRevert(stdError.indexOOBError);
        cat.tokenAt(user1, 2);

        // raw storage: length AND the dropped elements were zeroed
        assertEq(uint256(vm.load(address(cat), lenSlot)), 2);
        for (uint256 i = 2; i < 5; ++i) {
            assertEq(uint256(vm.load(address(cat), bytes32(uint256(dataStart) + i))), 0, "stale tail entry");
        }
    }

    /*------------------------------------------------------------------
      FINDING: duplicates are accepted, so an account can burn its 5-slot
      budget on one token and any consumer iterating the list
      double-counts the same preference.
    ------------------------------------------------------------------*/
    function test_CAT_duplicateTokensAreAccepted() public {
        address[] memory dup = new address[](5);
        for (uint256 i; i < 5; ++i) {
            dup[i] = tokens5[0];
        }

        vm.prank(user1);
        cat.setTokens(dup);

        assertEq(cat.tokenCount(user1), 5);
        for (uint256 i; i < 5; ++i) {
            assertEq(cat.tokenAt(user1, i), tokens5[0]);
        }
    }

    /*------------------------------------------------------------------
      FINDING: an account can never clear its list. Zero-length reverts
      and there is no delete entry point, so opting in is irreversible.
    ------------------------------------------------------------------*/
    function test_CAT_accountCanNeverClearItsList() public {
        vm.prank(user1);
        cat.setTokens(_list(2));

        address[] memory empty = new address[](0);
        vm.prank(user1);
        vm.expectRevert(CAT.EmptyTokenList.selector);
        cat.setTokens(empty);

        // A writer cannot clear it either.
        vm.prank(writer);
        vm.expectRevert(CAT.EmptyTokenList.selector);
        cat.setTokensFor(user1, empty);

        _assertNoSuchFunction("clearTokens()");
        _assertNoSuchFunction("deleteTokens(address)");
        _assertNoSuchFunction("removeTokens(address)");
        assertEq(cat.tokenCount(user1), 2);
    }

    /*------------------------------------------------------------------
      FINDING: a writer silently overwrites an account's own preference
      and the TokensSet event carries no operator field, so off-chain
      consumers cannot distinguish self-service from admin override.
    ------------------------------------------------------------------*/
    function test_CAT_writerOverwritesUserPreferenceIndistinguishably() public {
        address[] memory mine = new address[](1);
        mine[0] = tokens5[0];
        vm.prank(user1);
        cat.setTokens(mine);
        assertEq(cat.tokenAt(user1, 0), tokens5[0]);

        address[] memory theirs = new address[](1);
        theirs[0] = tokens5[4];

        // Byte-identical to a self-service update: no operator recorded.
        vm.expectEmit(true, false, false, true, address(cat));
        emit TokensSet(user1, theirs);
        vm.prank(writer);
        cat.setTokensFor(user1, theirs);

        assertEq(cat.tokenAt(user1, 0), tokens5[4], "user preference silently replaced");
        assertEq(cat.tokenCount(user1), 1);
    }

    /*------------------------------------------------------------------
      FINDING: entries are never validated as contracts, let alone ERC20s.
    ------------------------------------------------------------------*/
    function test_CAT_acceptsEoasAndNonErc20Addresses() public {
        address[] memory junk = new address[](3);
        junk[0] = makeAddr("catNotAToken"); // EOA, no code
        junk[1] = address(cat); // the registry itself
        junk[2] = address(this); // the test contract

        vm.prank(user1);
        cat.setTokens(junk);
        assertEq(cat.tokenCount(user1), 3);
        assertEq(cat.tokenAt(user1, 0), junk[0]);
        assertEq(junk[0].code.length, 0);
    }

    /*------------------------------------------------------------------
      L-7 (FIXED): CAT cannot initialize without an administrator.
    ------------------------------------------------------------------*/
    function test_CAT_initializeRejectsZeroOwner() public {
        CAT c = CAT(LibClone.clone(address(impl)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        c.initialize(address(0));
    }

    /*------------------------------------------------------------------
      FINDING: CAT is the only contract in this group without
      supportsInterface(), breaking the ERC-165 discovery pattern its
      sibling contracts advertise.
    ------------------------------------------------------------------*/
    function test_CAT_hasNoSupportsInterface() public {
        (bool ok,) = address(cat).staticcall(abi.encodeWithSignature("supportsInterface(bytes4)", bytes4(0x01ffc9a7)));
        assertFalse(ok);
    }

    /*------------------------------------------------------------------
      PROPERTIES THAT HOLD
    ------------------------------------------------------------------*/

    function test_CAT_boundsAndZeroAddressValidation_isCorrect() public {
        address[] memory six = new address[](6);
        for (uint256 i; i < 6; ++i) {
            six[i] = address(uint160(0x100 + i));
        }
        vm.prank(user1);
        vm.expectRevert(CAT.TooManyTokens.selector);
        cat.setTokens(six);

        vm.prank(user1);
        vm.expectRevert(CAT.EmptyTokenList.selector);
        cat.setTokens(new address[](0));

        // zero address rejected at every position
        for (uint256 pos; pos < 5; ++pos) {
            address[] memory l = _list(5);
            l[pos] = address(0);
            vm.prank(user1);
            vm.expectRevert(CAT.ZeroAddress.selector);
            cat.setTokens(l);
        }

        // exactly 5 is accepted
        vm.prank(user1);
        cat.setTokens(_list(5));
        assertEq(cat.tokenCount(user1), 5);
    }

    function test_CAT_writerAccessControl_isCorrect() public {
        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        cat.setTokensFor(user1, _list(1));

        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        cat.addWriter(attacker);

        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        cat.deleteWriter(writer);

        assertTrue(cat.isWriter(owner));
        assertTrue(cat.isWriter(writer));
        assertFalse(cat.isWriter(attacker));

        vm.prank(owner);
        cat.deleteWriter(writer);
        vm.prank(writer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        cat.setTokensFor(user1, _list(1));
    }

    function test_CAT_accountsAreIndependent_isCorrect() public {
        vm.prank(user1);
        cat.setTokens(_list(3));
        vm.prank(user2);
        cat.setTokens(_list(1));

        assertEq(cat.tokenCount(user1), 3);
        assertEq(cat.tokenCount(user2), 1);
        assertEq(cat.tokenCount(attacker), 0);
        assertEq(cat.getTokens(attacker).length, 0);
    }

    function test_CAT_orderIsPreserved_isCorrect() public {
        address[] memory l = new address[](3);
        l[0] = tokens5[4];
        l[1] = tokens5[0];
        l[2] = tokens5[2];
        vm.prank(user1);
        cat.setTokens(l);

        address[] memory got = cat.getTokens(user1);
        assertEq(got[0], tokens5[4]);
        assertEq(got[1], tokens5[0]);
        assertEq(got[2], tokens5[2]);
    }
}
