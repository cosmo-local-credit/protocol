// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Splitter} from "../../src/Splitter.sol";
import {RescueVault} from "../../src/RescueVault.sol";

/*//////////////////////////////////////////////////////////////////////////////
                        AUDIT PoC: Splitter + RescueVault
    Convention: a PASSING test whose name describes a defect means the defect
    is PRESENT. Tests suffixed `_holds` / `_isCorrect` encode properties that
    are actually satisfied by the code under audit.
//////////////////////////////////////////////////////////////////////////////*/

contract AuditPoCSplitterTest is Test {
    Splitter impl;
    Splitter splitter;

    address owner = makeAddr("fvOwner");
    address r1 = makeAddr("fvR1");
    address r2 = makeAddr("fvR2");
    address r3 = makeAddr("fvR3");

    uint256 constant PPM = 1_000_000;

    receive() external payable {}

    function setUp() public {
        impl = new Splitter();
        splitter = Splitter(payable(LibClone.clone(address(impl))));
        (address[] memory a, uint32[] memory p) = _two(r1, r2, 600_000, 400_000);
        splitter.initialize(owner, a, p);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _two(address a0, address a1, uint32 p0, uint32 p1)
        internal
        pure
        returns (address[] memory a, uint32[] memory p)
    {
        a = new address[](2);
        p = new uint32[](2);
        a[0] = a0;
        a[1] = a1;
        p[0] = p0;
        p[1] = p1;
    }

    function _three(address a0, address a1, address a2, uint32 p0, uint32 p1, uint32 p2)
        internal
        pure
        returns (address[] memory a, uint32[] memory p)
    {
        a = new address[](3);
        p = new uint32[](3);
        a[0] = a0;
        a[1] = a1;
        a[2] = a2;
        p[0] = p0;
        p[1] = p1;
        p[2] = p2;
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(splitter).call{value: amount}("");
        assertTrue(ok);
    }

    /*//////////////////////////////////////////////////////////////
        H-3 (FIXED): the allocation sum accumulates in uint256 and each
        element is bounded by PERCENTAGE_SCALE, so the sum cannot wrap.
                            Splitter.sol:82-101
    //////////////////////////////////////////////////////////////*/

    /// The stated invariant is "allocations sum to exactly 1_000_000". A
    /// multiset whose true sum is 1_000_000 + k*2**32 is now rejected instead
    /// of wrapping into the accepted range.
    function test_H3_splitter_uint32SumOverflow_isRejected() public {
        // 500_000 + 500_001 + 4_294_967_295 == 4_295_967_296 == 2**32 + 1_000_000
        (address[] memory a, uint32[] memory p) = _three(r1, r2, r3, 500_000, 500_001, 4_294_967_295);

        uint256 trueSum = uint256(p[0]) + uint256(p[1]) + uint256(p[2]);
        assertEq(trueSum, (1 << 32) + PPM, "constructed sum");
        assertTrue(trueSum != PPM, "true sum is NOT 100%");

        bytes32 hashBefore = splitter.getHash();
        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidAllocationsSum.selector);
        splitter.updateSplit(a, p);
        assertEq(splitter.getHash(), hashBefore, "no invalid split was committed");
    }

    /// The wrapped set that used to pay the last recipient zero never reaches
    /// distribution, because it can no longer be committed.
    function test_H3_splitter_overflowedSplit_cannotBeCommitted() public {
        (address[] memory a, uint32[] memory p) = _three(r1, r2, r3, 500_000, 500_001, 4_294_967_295);
        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidAllocationsSum.selector);
        splitter.updateSplit(a, p);

        _fund(1000);
        (address[] memory good, uint32[] memory goodP) = _two(r1, r2, 600_000, 400_000);
        splitter.distributeETH(good, goodP);

        assertEq(r1.balance, 600, "the committed split still distributes correctly");
        assertEq(r2.balance, 400);
        assertEq(address(splitter).balance, 0);
    }

    /// The variant whose leading allocations exceeded 100% - which used to
    /// freeze every asset in the contract - is rejected at validation, and a
    /// caller cannot smuggle it past distributeETH/distributeERC20 either.
    function test_H3_splitter_overflowedSplit_cannotFreezeFunds() public {
        // 900_000 + 900_000 + 4_294_167_296 == 2**32 + 1_000_000
        (address[] memory a, uint32[] memory p) = _three(r1, r2, r3, 900_000, 900_000, 4_294_167_296);
        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidAllocationsSum.selector);
        splitter.updateSplit(a, p);

        _fund(1 ether);

        vm.expectRevert(Splitter.InvalidAllocationsSum.selector);
        splitter.distributeETH(a, p);

        FvERC20 t = new FvERC20(false);
        t.mint(address(splitter), 1e18);
        vm.expectRevert(Splitter.InvalidAllocationsSum.selector);
        splitter.distributeERC20(address(t), a, p);

        // Nothing is stuck: the committed split still pays out.
        (address[] memory good, uint32[] memory goodP) = _two(r1, r2, 600_000, 400_000);
        splitter.distributeETH(good, goodP);
        splitter.distributeERC20(address(t), good, goodP);
        assertEq(address(splitter).balance, 0, "ETH released");
        assertEq(t.balanceOf(address(splitter)), 0, "tokens released");
    }

    /*//////////////////////////////////////////////////////////////
        M-12 (FIXED): zero and self recipients are rejected before a
        split can be committed or used.
    //////////////////////////////////////////////////////////////*/

    function test_splitter_zeroAddressRecipientCannotBurnETH() public {
        (address[] memory a, uint32[] memory p) = _two(address(0), r2, 600_000, 400_000);

        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidRecipient.selector);
        splitter.updateSplit(a, p);
    }

    function test_splitter_zeroAddressRecipientCannotBrickERC20Distribution() public {
        (address[] memory a, uint32[] memory p) = _two(address(0), r2, 600_000, 400_000);
        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidRecipient.selector);
        splitter.updateSplit(a, p);
    }

    function test_splitter_selfRecipientCannotRetainItsOwnShare() public {
        (address[] memory a, uint32[] memory p) = _two(address(splitter), r2, 600_000, 400_000);
        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidRecipient.selector);
        splitter.updateSplit(a, p);
    }

    /*//////////////////////////////////////////////////////////////
        F-S3: one hostile recipient blocks distribution for everyone
                    Splitter.sol:112 / 116 / 131 / 135
    //////////////////////////////////////////////////////////////*/

    function test_POC_splitter_oneRevertingRecipient_blocksEveryoneElse() public {
        FvRevertingReceiver bad = new FvRevertingReceiver();
        (address[] memory a, uint32[] memory p) = _two(address(bad), r2, 600_000, 400_000);
        vm.prank(owner);
        splitter.updateSplit(a, p);

        _fund(1 ether);

        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        splitter.distributeETH(a, p);

        assertEq(r2.balance, 0, "honest recipient cannot be paid");
        assertEq(address(splitter).balance, 1 ether, "whole balance held hostage");
    }

    /// safeTransferETH forwards all remaining gas, so a recipient can burn it
    /// instead of reverting: the distribution fails no matter how much gas the
    /// caller supplies.
    function test_POC_splitter_gasBurningRecipient_blocksEveryoneElse() public {
        FvGasBurner bad = new FvGasBurner();
        (address[] memory a, uint32[] memory p) = _two(address(bad), r2, 600_000, 400_000);
        vm.prank(owner);
        splitter.updateSplit(a, p);

        _fund(1 ether);

        (bool ok,) =
            address(splitter).call{gas: 3_000_000}(abi.encodeWithSelector(Splitter.distributeETH.selector, a, p));
        assertFalse(ok, "gas-burning recipient defeats the distribution");
        assertEq(r2.balance, 0);
        assertEq(address(splitter).balance, 1 ether);
    }

    /// Amplifier: the owner is the only escape hatch, and `initialize` happily
    /// accepts owner == address(0), which makes the freeze permanent.
    function test_POC_splitter_zeroOwnerPlusHostileRecipient_freezesFundsForever() public {
        Splitter s = Splitter(payable(LibClone.clone(address(impl))));
        FvRevertingReceiver bad = new FvRevertingReceiver();
        (address[] memory a, uint32[] memory p) = _two(address(bad), r2, 600_000, 400_000);

        s.initialize(address(0), a, p); // accepted: no non-zero-owner check
        assertEq(s.owner(), address(0), "owner is the unreachable zero address");

        vm.deal(address(s), 1 ether);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        s.distributeETH(a, p);

        // The only account that could repair the split is address(0), which
        // cannot originate a transaction. Every real caller is locked out.
        (address[] memory a2, uint32[] memory p2) = _two(r1, r2, 600_000, 400_000);
        vm.expectRevert();
        s.updateSplit(a2, p2);
        vm.prank(owner);
        vm.expectRevert();
        s.updateSplit(a2, p2);
        vm.prank(r1);
        vm.expectRevert();
        s.updateSplit(a2, p2);

        // Proof that address(0) is genuinely the owner (only reachable via a
        // cheatcode, never on a real chain).
        vm.prank(address(0));
        s.updateSplit(a2, p2);

        assertEq(address(s).balance, 1 ether, "1 ether locked behind an unreachable owner");
    }

    /*//////////////////////////////////////////////////////////////
        M-14 (FIXED): per-recipient fractional carry makes a dripped stream
        converge to the same entitlements as a lump distribution.
    //////////////////////////////////////////////////////////////*/

    function test_splitter_permissionlessDripDistribution_cannotStealStream() public {
        // r1 = 99.9999%, r2 = 0.0001% and last in the array.
        (address[] memory a, uint32[] memory p) = _two(r1, r2, 999_999, 1);
        vm.prank(owner);
        splitter.updateSplit(a, p);

        // r2 (or anyone) triggers the distribution after every 1 wei arrives.
        for (uint256 i; i < 200; ++i) {
            _fund(1);
            vm.prank(r2);
            splitter.distributeETH(a, p);
        }

        assertEq(r1.balance, 199, "99.9999% entitlement paid as whole units mature");
        assertEq(r2.balance, 0, "tiny recipient cannot capture rounding dust");
        assertEq(address(splitter).balance, 1, "one indivisible unit retained");

        // Control: one lump distribution of the same 200 wei has the same result.
        Splitter s = Splitter(payable(LibClone.clone(address(impl))));
        s.initialize(owner, a, p);
        vm.deal(address(s), 200);
        s.distributeETH(a, p);
        assertEq(r1.balance, 398, "drip and lump each pay 199");
        assertEq(r2.balance, 0);
        assertEq(address(s).balance, 1);

        // Once cumulative deposits reach one full PPM cycle, all fractional
        // entitlements mature and the retained unit is released exactly.
        _fund(999_800);
        splitter.distributeETH(a, p);
        assertEq(r1.balance, 1_000_198, "drip splitter has paid 999999 total");
        assertEq(r2.balance, 1);
        assertEq(address(splitter).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
        F-S5: owner can retroactively redirect already-deposited funds
                            Splitter.sol:39
    //////////////////////////////////////////////////////////////*/

    function test_POC_splitter_ownerRetroactivelyRedirectsDepositedFunds() public {
        (address[] memory a, uint32[] memory p) = _two(r1, r2, 600_000, 400_000);
        _fund(10 ether); // deposited under the 60/40 split

        address sink = makeAddr("fvSink");
        (address[] memory a2, uint32[] memory p2) = _two(owner, sink, 999_999, 1);
        vm.prank(owner);
        splitter.updateSplit(a2, p2);

        vm.expectRevert(Splitter.InvalidHash.selector);
        splitter.distributeETH(a, p); // old split no longer honoured

        splitter.distributeETH(a2, p2);
        assertEq(r1.balance, 0);
        assertEq(r2.balance, 0);
        assertEq(owner.balance, 9.99999 ether, "owner takes funds deposited under the old split");
    }

    /*//////////////////////////////////////////////////////////////
        F-S6: unbounded recipient count + O(n^2) validation re-run on
              every distribution. Splitter.sol:88-97
    //////////////////////////////////////////////////////////////*/

    function _measureValidationGas(uint256 n) internal returns (uint256 used) {
        address[] memory a = new address[](n);
        uint32[] memory p = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = address(uint160(0xF00000 + i));
            p[i] = 1;
        }
        p[n - 1] = uint32(1_000_000 - (n - 1));

        vm.prank(owner);
        splitter.updateSplit(a, p);

        // Balance is zero, so this measures validation + hashing alone: the
        // balance check happens after `_validateSplit` / `_validateHash`.
        uint256 g0 = gasleft();
        splitter.distributeETH(a, p);
        used = g0 - gasleft();
    }

    function test_POC_splitter_quadraticValidation_exceedsBlockGasLimit() public {
        uint256 g50 = _measureValidationGas(50);
        uint256 g100 = _measureValidationGas(100);
        uint256 g200 = _measureValidationGas(200);
        uint256 g400 = _measureValidationGas(400);
        emit log_named_uint("validate+hash gas, n=50 ", g50);
        emit log_named_uint("validate+hash gas, n=100", g100);
        emit log_named_uint("validate+hash gas, n=200", g200);
        emit log_named_uint("validate+hash gas, n=400", g400);

        // Superlinear: doubling n more than doubles the cost.
        assertGt(g100, 2 * g50);
        assertGt(g200, 2 * g100);
        assertGt(g400, 2 * g200);

        // And validation alone already blows past a 30M block gas limit, so the
        // split can never be distributed again.
        assertGt(g400, 30_000_000, "validation alone exceeds a 30M block gas limit");
    }

    /*//////////////////////////////////////////////////////////////
        F-S7: hash-commitment collision exists but is unreachable
                            Splitter.sol:74-80
    //////////////////////////////////////////////////////////////*/

    /// abi.encodePacked pads *array elements* to 32 bytes, and an address
    /// value that fits in 32 bytes is byte-identical to the same value as a
    /// uint32. So elements can be migrated across the array boundary and the
    /// keccak256 preimage is unchanged: a real collision.
    function test_POC_splitter_getHashCollisionExists_butIsUnreachable() public {
        (address[] memory a, uint32[] memory p) = _two(r1, r2, 600_000, 400_000);
        vm.prank(owner);
        splitter.updateSplit(a, p);

        // Move allocation[0] into `accounts` as an address: 3 accounts, 1 alloc.
        address[] memory aX = new address[](3);
        aX[0] = r1;
        aX[1] = r2;
        aX[2] = address(uint160(600_000));
        uint32[] memory pX = new uint32[](1);
        pX[0] = 400_000;

        // Identical preimage => identical committed hash.
        assertEq(
            keccak256(abi.encodePacked(aX, pX)),
            keccak256(abi.encodePacked(a, p)),
            "COLLISION: different (accounts, allocations) pair, same getHash()"
        );
        assertEq(splitter.getHash(), keccak256(abi.encodePacked(aX, pX)));

        // ...but `_validateSplit` runs BEFORE `_validateHash` and rejects the
        // unequal lengths, so the collision cannot be spent.
        _fund(1 ether);
        vm.expectRevert(Splitter.AccountsAndAllocationsMismatch.selector);
        splitter.distributeETH(aX, pX);
        assertEq(address(splitter).balance, 1 ether);
    }

    /// The reason no *spendable* collision exists: every accepted pair has
    /// n == m, encodePacked yields exactly 64*n bytes with a fixed boundary at
    /// 32*n, so equal digests force element-wise equality.
    function test_splitter_hashInjectiveOverValidatedDomain_holds() public pure {
        address[] memory a = new address[](3);
        uint32[] memory p = new uint32[](3);
        a[0] = address(0xAAAA);
        a[1] = address(0xBBBB);
        a[2] = address(0xCCCC);
        p[0] = 333_333;
        p[1] = 333_333;
        p[2] = 333_334;

        // 32 bytes per element for BOTH arrays: the boundary is length-derived.
        assertEq(abi.encodePacked(a).length, 96);
        assertEq(abi.encodePacked(p).length, 96);
        assertEq(abi.encodePacked(a, p).length, 192);

        // Any equal-length competitor with 32*n prefix + 32*n suffix must match
        // element-for-element; a single flipped element changes the digest.
        uint32[] memory p2 = new uint32[](3);
        p2[0] = 333_334;
        p2[1] = 333_333;
        p2[2] = 333_333;
        assertTrue(keccak256(abi.encodePacked(a, p)) != keccak256(abi.encodePacked(a, p2)));
    }

    /*//////////////////////////////////////////////////////////////
                        PROPERTIES THAT DO HOLD
    //////////////////////////////////////////////////////////////*/

    /// There is no nonReentrant guard: a recipient's `receive()` can and does
    /// re-enter `distributeETH`. It is harmless only because the balance is
    /// re-read at entry, so the nested call sees zero and no-ops.
    function test_splitter_noReentrancyGuardButReentryIsHarmless_holds() public {
        FvReenterer atk = new FvReenterer();
        // Attacker last => outer call has no transfers left when it re-enters.
        (address[] memory a, uint32[] memory p) = _three(r2, r3, address(atk), 250_000, 250_000, 500_000);
        vm.prank(owner);
        splitter.updateSplit(a, p);
        atk.arm(splitter, a, p);

        _fund(1 ether);
        splitter.distributeETH(a, p);

        assertTrue(atk.reentered(), "re-entered distributeETH: no guard exists");
        assertEq(address(atk).balance, 0.5 ether, "paid exactly its share, not twice");
        assertEq(r2.balance, 0.25 ether);
        assertEq(r3.balance, 0.25 ether);
        assertEq(address(splitter).balance, 0);
    }

    /// Re-entering from a non-last recipient cannot double-pay either: the
    /// outer call has already committed to paying out the full pre-reentry
    /// balance, the nested call drains it, and the outer call then reverts.
    function test_splitter_reentrancyFromNonLastRecipientRevertsWholeTx_holds() public {
        FvReenterer atk = new FvReenterer();
        (address[] memory a, uint32[] memory p) = _three(address(atk), r2, r3, 500_000, 250_000, 250_000);
        vm.prank(owner);
        splitter.updateSplit(a, p);
        atk.arm(splitter, a, p);

        _fund(1 ether);

        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        splitter.distributeETH(a, p);

        assertEq(address(atk).balance, 0, "no double payment");
        assertEq(r2.balance, 0);
        assertEq(address(splitter).balance, 1 ether);
    }

    /// Total paid always equals the balance read at entry: no over- or
    /// under-payment, and no stuck remainder (given well-formed recipients).
    function testFuzz_splitter_conservesFullBalance_holds(uint32 p0, uint96 amount) public {
        p0 = uint32(bound(uint256(p0), 1, PPM - 1));
        vm.assume(amount > 0);
        (address[] memory a, uint32[] memory p) = _two(r1, r2, p0, uint32(PPM - p0));
        vm.prank(owner);
        splitter.updateSplit(a, p);

        _fund(amount);
        splitter.distributeETH(a, p);

        assertEq(r1.balance, (uint256(amount) * p0) / PPM, "first entitlement");
        assertEq(r2.balance, (uint256(amount) * (PPM - p0)) / PPM, "second entitlement");
        assertEq(r1.balance + r2.balance + address(splitter).balance, amount, "conservation including dust");
        assertLe(address(splitter).balance, 1, "at most one indivisible unit retained");
    }

    /// Every recipient is rounded down equally and the indivisible remainder
    /// remains available for future fractional carry.
    function test_splitter_roundingDoesNotFavourArrayPosition() public {
        (address[] memory a, uint32[] memory p) = _three(r1, r2, r3, 333_333, 333_333, 333_334);
        vm.prank(owner);
        splitter.updateSplit(a, p);

        uint256 amount = 1 ether + 1;
        _fund(amount);
        splitter.distributeETH(a, p);

        uint256 s1 = (amount * 333_333) / PPM;
        uint256 s3 = (amount * 333_334) / PPM;
        assertEq(r1.balance, s1);
        assertEq(r2.balance, s1);
        assertEq(r3.balance, s3);
        assertEq(address(splitter).balance, amount - 2 * s1 - s3);
    }

    function test_splitter_zeroBalanceIsNoop_isCorrect() public {
        (address[] memory a, uint32[] memory p) = _two(r1, r2, 600_000, 400_000);
        splitter.distributeETH(a, p); // no revert
        FvERC20 t = new FvERC20(false);
        splitter.distributeERC20(address(t), a, p); // no revert
        assertEq(r1.balance, 0);
    }

    /// updateSplit re-runs every check that initialize runs.
    function test_splitter_updateSplitRevalidates_isCorrect() public {
        address[] memory a1 = new address[](1);
        uint32[] memory p1 = new uint32[](1);
        a1[0] = r1;
        p1[0] = 1_000_000;
        vm.prank(owner);
        vm.expectRevert(Splitter.TooFewAccounts.selector);
        splitter.updateSplit(a1, p1);

        address[] memory a2 = new address[](2);
        a2[0] = r1;
        a2[1] = r2;
        uint32[] memory p3 = new uint32[](3);
        p3[0] = 500_000;
        p3[1] = 250_000;
        p3[2] = 250_000;
        vm.prank(owner);
        vm.expectRevert(Splitter.AccountsAndAllocationsMismatch.selector);
        splitter.updateSplit(a2, p3);

        (address[] memory a, uint32[] memory p) = _two(r1, r2, 600_000, 300_000);
        vm.prank(owner);
        vm.expectRevert(Splitter.InvalidAllocationsSum.selector);
        splitter.updateSplit(a, p);

        (a, p) = _two(r1, r1, 600_000, 400_000);
        vm.prank(owner);
        vm.expectRevert(Splitter.DuplicateAccount.selector);
        splitter.updateSplit(a, p);

        (a, p) = _two(r1, r2, 1_000_000, 0);
        vm.prank(owner);
        vm.expectRevert(Splitter.AllocationMustBePositive.selector);
        splitter.updateSplit(a, p);
    }

    /// The O(n^2) scan is complete: a duplicate at any pair of indices is caught.
    function test_splitter_duplicateDetectionIsComplete_isCorrect() public {
        uint256 n = 6;
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                address[] memory a = new address[](n);
                uint32[] memory p = new uint32[](n);
                for (uint256 k; k < n; ++k) {
                    a[k] = address(uint160(0xD00000 + k));
                    p[k] = 100_000;
                }
                p[n - 1] = uint32(1_000_000 - 100_000 * (n - 1));
                a[j] = a[i]; // plant the duplicate
                vm.prank(owner);
                vm.expectRevert(Splitter.DuplicateAccount.selector);
                splitter.updateSplit(a, p);
            }
        }
    }

    /// A directly deployed Splitter is inert: the constructor disables the
    /// initializers, so it can never hold a split. ETH sent to it is stuck.
    function test_splitter_directDeployCannotBeInitialized_isCorrect() public {
        Splitter direct = new Splitter();
        (address[] memory a, uint32[] memory p) = _two(r1, r2, 600_000, 400_000);
        vm.expectRevert();
        direct.initialize(owner, a, p);

        vm.deal(address(direct), 1 ether);
        vm.expectRevert(Splitter.InvalidHash.selector);
        direct.distributeETH(a, p);
        assertEq(address(direct).balance, 1 ether);
    }

    /// ETH sent with calldata is rejected (no fallback), so no accidental
    /// mis-selector deposits get silently swallowed.
    function test_splitter_noFallback_isCorrect() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(splitter).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                RESCUE VAULT
//////////////////////////////////////////////////////////////////////////////*/

contract AuditPoCRescueVaultTest is Test {
    RescueVault vault;
    FvERC20 erc20;
    FvERC721 erc721;
    FvERC1155 erc1155;

    address admin = makeAddr("fvAdmin");
    address to = makeAddr("fvTo");
    address stranger = makeAddr("fvStranger");

    function setUp() public {
        vault = new RescueVault(admin);
        erc20 = new FvERC20(false);
        erc721 = new FvERC721();
        erc1155 = new FvERC1155();
    }

    /*//////////////////////////////////////////////////////////////
        F-R1: payable catch-all fallback silently succeeds for every
              unknown selector. RescueVault.sol:46
    //////////////////////////////////////////////////////////////*/

    function test_POC_rescueVault_fallbackSilentlySucceedsForAnyCall() public {
        vm.deal(stranger, 10 ether);

        // The vault squats an address a future contract was expected to take.
        // A user calling that contract's API gets success + empty returndata.
        vm.prank(stranger);
        (bool ok, bytes memory ret) =
            address(vault).call{value: 1 ether}(abi.encodeWithSignature("deposit(uint256)", 1 ether));
        assertTrue(ok, "misdirected deposit() reports SUCCESS");
        assertEq(ret.length, 0, "and returns nothing");
        assertEq(address(vault).balance, 1 ether, "ETH captured by the vault");

        // An ERC20-style transfer to the squatted address also "succeeds".
        vm.prank(stranger);
        (ok, ret) = address(vault).call(abi.encodeWithSignature("transfer(address,uint256)", to, 1));
        assertTrue(ok);
        assertEq(ret.length, 0);
    }

    /// Compound with the immutable admin: an operator "rotating" the admin via
    /// a raw call sees success, but nothing changed and there is no rotation
    /// path at all. RescueVault.sol:28,46
    function test_POC_rescueVault_adminIsImmutableButRotationCallsFakeSuccess() public {
        address newAdmin = makeAddr("fvNewAdmin");

        vm.prank(admin);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("setAdmin(address)", newAdmin));
        assertTrue(ok, "setAdmin() reports SUCCESS");
        assertEq(vault.admin(), admin, "but admin is unchanged and unchangeable");

        vm.prank(admin);
        (ok,) = address(vault).call(abi.encodeWithSignature("transferOwnership(address)", newAdmin));
        assertTrue(ok);
        assertEq(vault.admin(), admin);

        // Assets are unrecoverable if the admin key is lost.
        erc20.mint(address(vault), 1e18);
        vm.prank(newAdmin);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC20(address(erc20), to);
    }

    /*//////////////////////////////////////////////////////////////
        F-R2: batch sweeps are all-or-nothing and mishandle duplicates
                    RescueVault.sol:66-73, 81-85, 94-106
    //////////////////////////////////////////////////////////////*/

    /// sweepERC1155Batch reads every amount from `balanceOf` BEFORE the single
    /// batch transfer, so a repeated id is counted twice and the whole sweep
    /// reverts for insufficient balance.
    function test_POC_rescueVault_erc1155BatchDuplicateId_revertsWholeSweep() public {
        erc1155.mint(address(vault), 42, 9);
        erc1155.mint(address(vault), 43, 10);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 42;
        ids[1] = 43;
        ids[2] = 42; // duplicate

        vm.prank(admin);
        vm.expectRevert(bytes("BALANCE"));
        vault.sweepERC1155Batch(address(erc1155), ids, to);

        assertEq(erc1155.balanceOf(address(vault), 42), 9, "nothing swept");
        assertEq(erc1155.balanceOf(address(vault), 43), 10);
    }

    function test_POC_rescueVault_erc721BatchDuplicateId_revertsWholeSweep() public {
        erc721.mint(address(vault), 7);
        erc721.mint(address(vault), 8);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 7;
        ids[1] = 8;
        ids[2] = 7; // duplicate

        vm.prank(admin);
        vm.expectRevert(bytes("OWNER"));
        vault.sweepERC721s(address(erc721), ids, to);

        assertEq(erc721.ownerOf(7), address(vault), "nothing swept");
        assertEq(erc721.ownerOf(8), address(vault));
    }

    /// One hostile / broken token in `sweepERC20s` blocks the rescue of every
    /// other token in the same call.
    function test_POC_rescueVault_oneBadTokenBlocksWholeErc20Batch() public {
        FvBadERC20 bad = new FvBadERC20();
        FvERC20 good2 = new FvERC20(false);
        erc20.mint(address(vault), 1e18);
        good2.mint(address(vault), 2e18);

        address[] memory tokens = new address[](3);
        tokens[0] = address(erc20);
        tokens[1] = address(bad);
        tokens[2] = address(good2);

        vm.prank(admin);
        vm.expectRevert();
        vault.sweepERC20s(tokens, to);

        assertEq(erc20.balanceOf(to), 0, "healthy token also blocked");
        assertEq(good2.balanceOf(to), 0);

        // Only the per-token entrypoint gets around it.
        vm.prank(admin);
        vault.sweepERC20(address(erc20), to);
        assertEq(erc20.balanceOf(to), 1e18);
    }

    /// A codeless address in `sweepERC20s` is silently treated as a swept
    /// token of amount 0 by nothing -- it reverts, so an empty-token typo also
    /// kills the batch.
    function test_POC_rescueVault_codelessTokenInBatch_reverts() public {
        erc20.mint(address(vault), 1e18);
        address[] memory tokens = new address[](2);
        tokens[0] = address(erc20);
        tokens[1] = makeAddr("fvNotAToken");

        vm.prank(admin);
        vm.expectRevert();
        vault.sweepERC20s(tokens, to);
        assertEq(erc20.balanceOf(to), 0);
    }

    /*//////////////////////////////////////////////////////////////
        F-R3: sweepERC721s skips the zero-recipient check on empty input
                            RescueVault.sol:81-85
    //////////////////////////////////////////////////////////////*/

    function test_POC_rescueVault_sweepERC721sEmptyArray_skipsZeroAddressCheck() public {
        uint256[] memory none = new uint256[](0);

        // Every other sweep rejects to == address(0)...
        vm.prank(admin);
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepETH(address(0));
        vm.prank(admin);
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC1155Batch(address(erc1155), none, address(0));

        // ...but this one accepts it, because the check lives in the loop body.
        vm.prank(admin);
        vault.sweepERC721s(address(erc721), none, address(0)); // no revert
    }

    /*//////////////////////////////////////////////////////////////
                        PROPERTIES THAT DO HOLD
    //////////////////////////////////////////////////////////////*/

    function test_rescueVault_accessControlOnEverySweep_isCorrect() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.startPrank(stranger);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepETH(to);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC20(address(erc20), to);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC20s(tokens, to);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC721(address(erc721), 1, to);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC721s(address(erc721), ids, to);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC1155(address(erc1155), 1, to);
        vm.expectRevert(RescueVault.Unauthorized.selector);
        vault.sweepERC1155Batch(address(erc1155), ids, to);
        vm.stopPrank();
    }

    function test_rescueVault_zeroRecipientRejectedOnAllNonEmptyPaths_isCorrect() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.startPrank(admin);
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepETH(address(0));
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC20(address(erc20), address(0));
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC20s(tokens, address(0));
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC721(address(erc721), 1, address(0));
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC721s(address(erc721), ids, address(0));
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC1155(address(erc1155), 1, address(0));
        vm.expectRevert(RescueVault.ZeroAddress.selector);
        vault.sweepERC1155Batch(address(erc1155), ids, address(0));
        vm.stopPrank();
    }

    /// sweepETH forwards all gas, checks the return value, and re-reads
    /// selfbalance() at call time, so a reentrant sweep gets nothing.
    function test_rescueVault_sweepETHReentrancyIsHarmless_holds() public {
        FvSweepReenterer sink = new FvSweepReenterer(vault);
        vm.deal(address(vault), 5 ether);

        // The reentrant call comes from the sink, which is not the admin.
        vm.prank(admin);
        uint256 swept = vault.sweepETH(address(sink));
        assertEq(swept, 5 ether);
        assertEq(address(sink).balance, 5 ether);
        assertEq(address(vault).balance, 0);
        assertTrue(sink.reentered());
        assertFalse(sink.reentrySucceeded(), "reentrant sweep is blocked by onlyAdmin");
    }

    /// A `to` that cannot receive ETH makes sweepETH revert (return value is
    /// checked, no silent loss); the admin simply picks another destination.
    function test_rescueVault_sweepETHChecksReturnValue_isCorrect() public {
        FvNoReceive nr = new FvNoReceive();
        vm.deal(address(vault), 1 ether);

        vm.prank(admin);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        vault.sweepETH(address(nr));
        assertEq(address(vault).balance, 1 ether, "no silent loss");

        vm.prank(admin);
        vault.sweepETH(to);
        assertEq(to.balance, 1 ether);
    }

    function test_rescueVault_receiverHookSelectors_isCorrect() public view {
        assertEq(
            vault.onERC721Received(address(1), address(2), 3, ""),
            bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
        );
        assertEq(
            vault.onERC1155Received(address(1), address(2), 3, 4, ""),
            bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))
        );
        uint256[] memory e = new uint256[](0);
        assertEq(
            vault.onERC1155BatchReceived(address(1), address(2), e, e, ""),
            bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))
        );

        // ERC165 ids: IERC721Receiver == 0x150b7a02, IERC1155Receiver == 0x4e2312e0.
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertTrue(vault.supportsInterface(0x150b7a02));
        assertTrue(vault.supportsInterface(0x4e2312e0));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    /// safeTransferFrom pushes into the vault genuinely work end to end.
    function test_rescueVault_safeTransferFromIntoVault_isCorrect() public {
        erc721.mint(stranger, 11);
        vm.prank(stranger);
        erc721.safeTransferFrom(stranger, address(vault), 11);
        assertEq(erc721.ownerOf(11), address(vault));

        erc1155.mint(stranger, 5, 3);
        vm.prank(stranger);
        erc1155.safeTransferFrom(stranger, address(vault), 5, 3, "");
        assertEq(erc1155.balanceOf(address(vault), 5), 3);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        ids[0] = 6;
        amts[0] = 4;
        erc1155.mint(stranger, 6, 4);
        vm.prank(stranger);
        erc1155.safeBatchTransferFrom(stranger, address(vault), ids, amts, "");
        assertEq(erc1155.balanceOf(address(vault), 6), 4);

        // ...and sweep back out.
        vm.startPrank(admin);
        vault.sweepERC721(address(erc721), 11, to);
        vault.sweepERC1155(address(erc1155), 5, to);
        vm.stopPrank();
        assertEq(erc721.ownerOf(11), to);
        assertEq(erc1155.balanceOf(to, 5), 3);
    }

    function test_rescueVault_erc1155BatchReadsAmountsBeforeTransfer_isCorrect() public {
        erc1155.mint(address(vault), 42, 9);
        erc1155.mint(address(vault), 43, 10);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 42;
        ids[1] = 43;

        vm.prank(admin);
        uint256[] memory amts = vault.sweepERC1155Batch(address(erc1155), ids, to);
        assertEq(amts[0], 9);
        assertEq(amts[1], 10);
        assertEq(erc1155.balanceOf(to, 42), 9);
        assertEq(erc1155.balanceOf(to, 43), 10);
        assertEq(erc1155.balanceOf(address(vault), 42), 0);
    }

    function test_rescueVault_constructorPayableSeedsSweepableETH_isCorrect() public {
        vm.deal(address(this), 3 ether);
        RescueVault v = new RescueVault{value: 3 ether}(admin);
        assertEq(address(v).balance, 3 ether);
        vm.prank(admin);
        assertEq(v.sweepETH(to), 3 ether);
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////////////////////
                                    MOCKS
//////////////////////////////////////////////////////////////////////////////*/

contract FvERC20 {
    mapping(address => uint256) public balanceOf;
    bool immutable rejectZero;

    constructor(bool rejectZero_) {
        rejectZero = rejectZero_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (rejectZero) require(to != address(0), "ERC20: transfer to the zero address");
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FvBadERC20 {
    function balanceOf(address) external pure returns (uint256) {
        return 1e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("BLACKLISTED");
    }
}

contract FvRevertingReceiver {
    receive() external payable {
        revert("NOPE");
    }
}

contract FvGasBurner {
    uint256 public sink;

    receive() external payable {
        // Burn every wei of gas that was forwarded.
        while (true) {
            sink = sink + 1;
        }
    }
}

contract FvReenterer {
    Splitter public s;
    address[] internal a;
    uint32[] internal p;
    bool public armed;
    bool public reentered;

    function arm(Splitter s_, address[] memory a_, uint32[] memory p_) external {
        s = s_;
        a = a_;
        p = p_;
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            reentered = true;
            s.distributeETH(a, p);
        }
    }
}

contract FvSweepReenterer {
    RescueVault public vault;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(RescueVault v) {
        vault = v;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            (bool ok,) = address(vault).call(abi.encodeWithSelector(RescueVault.sweepETH.selector, address(this)));
            reentrySucceeded = ok;
        }
    }
}

contract FvNoReceive {
    uint256 public x;
}

interface IFvERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

interface IFvERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        returns (bytes4);
}

contract FvERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "OWNER");
        require(msg.sender == from, "SENDER");
        ownerOf[tokenId] = to;
        if (to.code.length != 0) {
            require(
                IFvERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IFvERC721Receiver.onERC721Received.selector,
                "RECEIVER"
            );
        }
    }
}

contract FvERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(msg.sender == from, "SENDER");
        require(balanceOf[from][id] >= amount, "BALANCE");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        if (to.code.length != 0) {
            require(
                IFvERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data)
                    == IFvERC1155Receiver.onERC1155Received.selector,
                "RECEIVER"
            );
        }
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(msg.sender == from, "SENDER");
        require(ids.length == amounts.length, "LENGTH");
        for (uint256 i; i < ids.length; ++i) {
            require(balanceOf[from][ids[i]] >= amounts[i], "BALANCE");
            balanceOf[from][ids[i]] -= amounts[i];
            balanceOf[to][ids[i]] += amounts[i];
        }
        if (to.code.length != 0) {
            require(
                IFvERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data)
                    == IFvERC1155Receiver.onERC1155BatchReceived.selector,
                "RECEIVER"
            );
        }
    }
}
