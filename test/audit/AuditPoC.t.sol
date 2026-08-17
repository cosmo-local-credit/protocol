// SPDX-License-Identifier: AGPL-3.0
// Proof-of-concept exploits / correctness counter-examples produced by the
// security audit of SwapPool, OracleQuoter and SwapRouter.
//
// Each test is named after the finding it demonstrates in audit/AUDIT.md.
// A PASSING test here means the vulnerability is PRESENT (the assertions
// encode the broken behaviour, not the desired behaviour).
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SwapPool} from "../../src/SwapPool.sol";
import {SwapRouter} from "../../src/SwapRouter.sol";
import {OracleQuoter} from "../../src/OracleQuoter.sol";
import {DecimalQuoter} from "../../src/DecimalQuoter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {ILimiter} from "../../src/interfaces/ILimiter.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

contract AuditPoCTest is Test {
    uint256 constant PPM = 1_000_000;

    SwapPool poolImpl;
    OracleQuoter quoterImpl;

    AudRegistry registry;
    AudLimiter limiter;
    AudFeePolicy feePolicy;
    AudPfc pfc;

    address owner = makeAddr("poolOwner");
    address feeAddress = makeAddr("poolFeeAddress");
    address attacker = makeAddr("attacker");
    address user = makeAddr("user");

    function setUp() public {
        poolImpl = new SwapPool();
        quoterImpl = new OracleQuoter();
        registry = new AudRegistry();
        limiter = new AudLimiter();
        feePolicy = new AudFeePolicy();
        pfc = new AudPfc();
    }

    // ---------------------------------------------------------------- helpers

    function _pool(address quoter, bool feesDecoupled) internal returns (SwapPool p) {
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
            quoter,
            feesDecoupled,
            address(pfc)
        );
    }

    function _allow(SwapPool p, address token, uint256 lim) internal {
        registry.add(token);
        limiter.setLimit(token, address(p), lim);
    }

    function _oracleQuoter(address base) internal returns (OracleQuoter q) {
        q = OracleQuoter(LibClone.clone(address(quoterImpl)));
        q.initialize(owner, base);
    }

    // =====================================================================
    // C-1 (FIXED)  The multiplier is capped at parity, so it can only ever
    //              widen the pool's margin, and _swap rejects tokenIn ==
    //              tokenOut outright for every quoter.
    // =====================================================================
    function test_C1_multiplierAboveParity_isRejected() public {
        AudERC20 tkn = new AudERC20("Sarafu", "SRF", 6);
        MockChainlinkAggregator feed = new MockChainlinkAggregator(8, "SRF/USD", 1e8);

        OracleQuoter q = _oracleQuoter(address(tkn));
        vm.startPrank(owner);
        q.setOracle(address(tkn), address(feed));
        vm.expectRevert(OracleQuoter.InvalidMultiplier.selector);
        q.setMultiplier(1_000_001);
        vm.expectRevert(OracleQuoter.InvalidMultiplier.selector);
        q.setMultiplier(1_100_000);
        q.setMultiplier(1_000_000); // parity is the ceiling and is allowed
        vm.stopPrank();

        assertEq(q.multiplier(), PPM);
    }

    function test_C1_sameTokenSwap_isRejected() public {
        AudERC20 tkn = new AudERC20("Sarafu", "SRF", 6);
        MockChainlinkAggregator feed = new MockChainlinkAggregator(8, "SRF/USD", 1e8);

        OracleQuoter q = _oracleQuoter(address(tkn));
        vm.startPrank(owner);
        q.setOracle(address(tkn), address(feed));
        q.setMultiplier(1_000_000);
        vm.stopPrank();

        SwapPool p = _pool(address(q), false);
        _allow(p, address(tkn), type(uint256).max);
        feePolicy.setFee(address(tkn), address(tkn), 10_000);

        tkn.mint(address(p), 100_000e6);
        tkn.mint(attacker, 1_000e6);

        vm.startPrank(attacker);
        tkn.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.InvalidToken.selector);
        p.withdraw(address(tkn), address(tkn), 1_000e6);
        vm.stopPrank();

        assertEq(tkn.balanceOf(attacker), 1_000e6, "no profit, no input consumed");
        assertEq(tkn.balanceOf(address(p)), 100_000e6, "pool untouched");
    }

    // =====================================================================
    // C-1 (FIXED)  An A->B->A round trip at the highest legal multiplier can
    //              no longer return more than it started with.
    // =====================================================================
    function test_C1_roundTripArbitrage_neverProfits() public {
        AudERC20 a = new AudERC20("A", "A", 6);
        AudERC20 b = new AudERC20("B", "B", 6);
        MockChainlinkAggregator fa = new MockChainlinkAggregator(8, "A/USD", 1e8);
        MockChainlinkAggregator fb = new MockChainlinkAggregator(8, "B/USD", 1e8);

        OracleQuoter q = _oracleQuoter(address(a));
        vm.startPrank(owner);
        q.setOracle(address(a), address(fa));
        q.setOracle(address(b), address(fb));
        q.setMultiplier(1_000_000); // the highest value the contract accepts
        vm.stopPrank();

        SwapPool p = _pool(address(q), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000);
        feePolicy.setFee(address(b), address(a), 10_000);

        a.mint(address(p), 1_000_000e6);
        b.mint(address(p), 1_000_000e6);
        a.mint(attacker, 1_000e6);

        uint256 start = a.balanceOf(attacker);

        vm.startPrank(attacker);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        for (uint256 i = 0; i < 5; i++) {
            uint256 aBal = a.balanceOf(attacker);
            p.withdraw(address(b), address(a), aBal);
            uint256 bBal = b.balanceOf(attacker);
            p.withdraw(address(a), address(b), bBal);
        }
        vm.stopPrank();

        assertLt(a.balanceOf(attacker), start, "5 round trips only ever lose to the fee");
    }

    // =====================================================================
    // F-02 (FIXED) OracleQuoter reverses the multiplier before the rate
    //       conversion, preserving the documented IQuoter round-trip guarantee.
    // =====================================================================
    function test_F02_reverseValueFor_roundtripInvariant_holds() public {
        (OracleQuoter q, address small, address big) = _crossDecimalQuoter();

        // Ask for 1 unit of the 6-decimal token, paying with the 18-decimal token.
        uint256 needed = q.reverseValueFor(small, big, 1);
        uint256 actual = q.valueFor(small, big, needed);

        assertGe(actual, 1, "round trip covers a 1-unit request");
    }

    function test_F02_reverseValueFor_coversRequestedOutputAtScale() public {
        (OracleQuoter q, address small, address big) = _crossDecimalQuoter();

        uint256 desired = 100e6;
        uint256 needed = q.reverseValueFor(small, big, desired);
        uint256 actual = q.valueFor(small, big, needed);

        assertGe(actual, desired, "no shortfall at realistic sizes");
    }

    /// The invariant does not merely fail at one point — it fails for the
    /// large majority of request sizes.
    function test_F02_reverseValueFor_hasNoRoundtripViolations() public {
        (OracleQuoter q, address small, address big) = _crossDecimalQuoter();

        uint256 violations;
        for (uint256 x = 1; x <= 100; x++) {
            if (q.valueFor(small, big, q.reverseValueFor(small, big, x)) < x) violations++;
        }
        assertEq(violations, 0, "no request size under-delivers");
    }

    /// 6-decimal token out, 18-decimal token in, equal prices, multiplier != 1.0
    function _crossDecimalQuoter() internal returns (OracleQuoter q, address small, address big) {
        AudERC20 s = new AudERC20("Small", "SML", 6);
        AudERC20 g = new AudERC20("Big", "BIG", 18);
        MockChainlinkAggregator fs = new MockChainlinkAggregator(8, "SML/USD", 1e8);
        MockChainlinkAggregator fg = new MockChainlinkAggregator(8, "BIG/USD", 1e8);

        q = _oracleQuoter(address(s));
        vm.startPrank(owner);
        q.setOracle(address(s), address(fs));
        q.setOracle(address(g), address(fg));
        q.setMultiplier(950_000); // 0.95x, inside the allowed range
        vm.stopPrank();

        small = address(s);
        big = address(g);
    }

    // =====================================================================
    // F-02 (FIXED) The corrected inverse reaches the SwapRouter's documented
    //       round-trip property.
    // =====================================================================
    function test_F02_router_quoteExactOutput_coversRequest() public {
        (OracleQuoter q, address small, address big) = _crossDecimalQuoter();

        SwapPool p = _pool(address(q), false);
        _allow(p, small, type(uint256).max);
        _allow(p, big, type(uint256).max);
        // Zero pool fee: _reverseNetToQuoted adds no ceiling slack, so the
        // quoter's own rounding defect reaches the router unmasked.
        feePolicy.setFee(big, small, 0);

        SwapRouter router = new SwapRouter();
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](1);
        path[0] = SwapRouter.Hop(address(p), big, small);

        uint256 desired = 100e6;
        uint256 amountIn = router.quoteExactOutput(path, desired);
        uint256 amountOut = router.quoteExactInput(path, amountIn);

        assertGe(amountOut, desired, "documented router round-trip property holds");
    }

    // =====================================================================
    // C-2 (FIXED)  _deposit measures the balance delta, so a fee-on-transfer
    //              token is priced on what the pool actually banked.
    // =====================================================================
    function test_C2_feeOnTransferToken_doesNotLeakLiquidity() public {
        AudFotERC20 fot = new AudFotERC20("FeeOnTransfer", "FOT", 18, 1000); // 10% burn
        AudERC20 good = new AudERC20("Good", "GOOD", 18);

        SwapPool p = _pool(address(0), false); // no quoter -> 1:1
        _allow(p, address(fot), type(uint256).max);
        _allow(p, address(good), type(uint256).max);
        feePolicy.setFee(address(fot), address(good), 10_000); // 1%

        good.mint(address(p), 100_000e18);
        fot.mint(attacker, 1_000e18);

        vm.startPrank(attacker);
        fot.approve(address(p), type(uint256).max);
        p.withdraw(address(good), address(fot), 1_000e18);
        vm.stopPrank();

        assertEq(fot.balanceOf(address(p)), 900e18, "pool received 900");
        assertEq(good.balanceOf(attacker), 891e18, "and paid out on 900, less the 1% pool fee");
        // Pool net position on a 1:1 pair: +900 in, -891 out => no leak.
        assertGt(fot.balanceOf(address(p)), good.balanceOf(attacker), "the pool keeps the fee");
    }

    // =====================================================================
    // C-2 (FIXED)  Even with tokenRegistry and tokenLimiter both unset, a
    //              token whose transferFrom moves nothing delivers a zero
    //              balance delta and the swap reverts.
    // =====================================================================
    function test_C2_ungatedPool_notDrainedByWorthlessToken() public {
        AudERC20 real = new AudERC20("Real", "REAL", 18);
        AudLyingERC20 fake = new AudLyingERC20("Fake", "FAKE", 18);

        SwapPool p = SwapPool(LibClone.clone(address(poolImpl)));
        p.initialize(
            "P",
            "P",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(0), // no token registry  -> "any token is allowed"
            address(0), // no token limiter   -> "deposits are uncapped"
            address(0), // no quoter          -> 1:1
            false,
            address(pfc)
        );

        real.mint(address(p), 100_000e18);
        assertEq(real.balanceOf(attacker), 0);

        vm.prank(attacker);
        vm.expectRevert(SwapPool.TransferFailed.selector);
        p.withdraw(address(real), address(fake), 100_000e18);

        assertEq(real.balanceOf(attacker), 0, "nothing extracted");
        assertEq(real.balanceOf(address(p)), 100_000e18, "pool intact");
    }

    /// The limiter used to be the only thing standing between an ungated pool
    /// and a lying token. Granting the unknown token an unlimited allowance now
    /// changes nothing: the balance delta is still zero.
    function test_C2_limiterIsNoLongerTheOnlyGuard() public {
        AudERC20 real = new AudERC20("Real", "REAL", 18);
        AudLyingERC20 fake = new AudLyingERC20("Fake", "FAKE", 18);

        SwapPool p = SwapPool(LibClone.clone(address(poolImpl)));
        p.initialize(
            "P",
            "P",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(0),
            address(limiter),
            address(0),
            false,
            address(pfc)
        );
        real.mint(address(p), 100_000e18);

        vm.prank(attacker);
        vm.expectRevert(SwapPool.LimitExceeded.selector);
        p.withdraw(address(real), address(fake), 100_000e18);

        // Give the unknown token any nonzero limit and the swap still fails.
        limiter.setLimit(address(fake), address(p), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert(SwapPool.TransferFailed.selector);
        p.withdraw(address(real), address(fake), 100_000e18);
        assertEq(real.balanceOf(attacker), 0, "no drain once a limit exists either");
    }

    /// Supporting detail for the coverage-gap section: a token that returns no
    /// data from transferFrom (a real-world non-conformance) makes _deposit
    /// revert on ABI decoding rather than with TransferFailed.
    function test_POC_noReturnValueToken_revertsOnDecode() public {
        AudERC20 good = new AudERC20("Good", "GOOD", 18);
        AudVoidERC20 silent = new AudVoidERC20();

        SwapPool p = _pool(address(0), false);
        _allow(p, address(silent), type(uint256).max);
        _allow(p, address(good), type(uint256).max);
        good.mint(address(p), 1_000e18);

        vm.prank(attacker);
        vm.expectRevert(); // ABI decode failure, not TransferFailed
        p.withdraw(address(good), address(silent), 1e18);
    }

    /// Supporting detail for I-4: isSealed rejects its own maximum, and
    /// seal(0) is accepted as an event-emitting no-op.
    function test_POC_I04_sealStateMachineEdges() public {
        SwapPool p = _pool(address(0), false);

        vm.startPrank(owner);
        p.seal(0); // accepted, changes nothing, still emits SealStateChange
        assertEq(p.sealState(), 0);

        p.seal(7);
        assertEq(p.sealState(), 7);
        assertTrue(p.isSealed(7));
        assertFalse(p.isSealed(0), "registry and limiter bits still open");

        // After only the original three bits, registry and limiter stay writable.
        p.setTokenRegistry(address(0xdead));
        p.setTokenLimiter(address(0xbeef));
        assertEq(p.tokenRegistry(), address(0xdead));
        assertEq(p.tokenLimiter(), address(0xbeef));

        p.seal(24); // 8 | 16
        assertTrue(p.isSealed(0));
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setTokenRegistry(address(0));
        vm.expectRevert(SwapPool.Sealed.selector);
        p.setTokenLimiter(address(0));
        vm.stopPrank();

        vm.expectRevert(SwapPool.InvalidState.selector);
        p.isSealed(32);
    }

    // =====================================================================
    // M-2 (FIXED as a side effect)  fees[] is still credited after the
    //      outbound transfers, but the swap path is now nonReentrant, so a
    //      tokenOut with a transfer hook can no longer re-enter and spend the
    //      not-yet-reserved fee.
    // =====================================================================
    function test_M2_reentrancy_cannotCorruptDecoupledFeeAccounting() public {
        AudERC20 tin = new AudERC20("In", "IN", 18);
        AudHookERC20 tout = new AudHookERC20("Out", "OUT", 18);

        SwapPool p = _pool(address(0), true); // feesDecoupled = true
        _allow(p, address(tin), type(uint256).max);
        _allow(p, address(tout), type(uint256).max);
        feePolicy.setFee(address(tin), address(tout), 100_000); // 10%

        tout.mint(address(p), 1_000e18);

        AudReenter bot = new AudReenter(p, address(tout), address(tin));
        tin.mint(address(bot), 1_100e18);
        tout.setHook(address(bot));

        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        bot.attack(1_000e18, 100e18);

        assertEq(p.fees(address(tout)), 0, "no fee was credited");
        assertEq(tout.balanceOf(address(p)), 1_000e18, "pool balance intact");

        // A single, non-nested swap still keeps fees[] within the balance.
        tout.setHook(address(0));
        AudERC20 tin2 = tin;
        tin2.mint(attacker, 100e18);
        vm.startPrank(attacker);
        tin2.approve(address(p), type(uint256).max);
        p.withdraw(address(tout), address(tin2), 100e18);
        vm.stopPrank();

        assertEq(p.fees(address(tout)), 10e18, "10% of 100");
        assertLe(p.fees(address(tout)), tout.balanceOf(address(p)), "fees never exceed the balance");

        vm.prank(owner);
        assertEq(p.withdraw(address(tout)), 10e18, "fee collection still works");
    }

    // =====================================================================
    // F-05  tokenOut is never checked against tokenRegistry, so the
    //       whitelist only constrains the input side of a swap.
    // =====================================================================
    function test_POC_F05_tokenOut_bypassesRegistryWhitelist() public {
        AudERC20 allowed = new AudERC20("Allowed", "ALW", 18);
        AudERC20 delisted = new AudERC20("Delisted", "DEL", 18);

        SwapPool p = _pool(address(0), false); // 1:1
        _allow(p, address(allowed), type(uint256).max);
        // `delisted` is deliberately NOT registered.
        limiter.setLimit(address(delisted), address(p), type(uint256).max);

        delisted.mint(address(p), 10_000e18);
        allowed.mint(attacker, 1_000e18);
        feePolicy.setFee(address(allowed), address(delisted), 0);

        // Depositing the unregistered token is correctly blocked...
        delisted.mint(attacker, 1e18);
        vm.startPrank(attacker);
        delisted.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.UnauthorizedToken.selector);
        p.deposit(address(delisted), 1e18);

        // ...but receiving it out of the pool is not.
        allowed.approve(address(p), type(uint256).max);
        p.withdraw(address(delisted), address(allowed), 1_000e18);
        vm.stopPrank();

        assertEq(delisted.balanceOf(attacker), 1_001e18, "unregistered token extracted");
    }

    // =====================================================================
    // F-06  A pool fee above ~90.9% makes the netValue subtraction (and the
    //       reverse-fee denominator) underflow, bricking swaps and quotes.
    // =====================================================================
    function test_M5_highPoolFee_revertsFeeTooHigh() public {
        AudERC20 a = new AudERC20("A", "A", 18);
        AudERC20 b = new AudERC20("B", "B", 18);

        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);

        pfc.setFee(100_000); // 10% protocol fee
        pfc.setRecipient(makeAddr("protocol"));
        feePolicy.setFee(address(a), address(b), 909_091); // just past the safe bound

        b.mint(address(p), 100_000e18);
        a.mint(attacker, 1_000e18);

        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountOut(address(b), address(a), 1_000e18);

        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.getAmountIn(address(b), address(a), 1e18);

        vm.startPrank(attacker);
        a.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        p.withdraw(address(b), address(a), 1_000e18);
        vm.stopPrank();

        assertEq(a.balanceOf(attacker), 1_000e18, "input not taken");

        feePolicy.setFee(address(a), address(b), 909_090);
        assertGt(p.getAmountOut(address(b), address(a), 1_000e18), 0);
        assertGt(p.getAmountIn(address(b), address(a), 1e18), 0);
        vm.prank(attacker);
        p.withdraw(address(b), address(a), 1_000e18);
        assertGt(b.balanceOf(attacker), 0);
    }

    // =====================================================================
    // F-07  With feeAddress == 0 the pool still deducts the pool fee from
    //       the user's output but never records it in fees[].
    // =====================================================================
    function test_POC_F07_zeroFeeAddress_confiscatesFeeSilently() public {
        AudERC20 a = new AudERC20("A", "A", 18);
        AudERC20 b = new AudERC20("B", "B", 18);

        SwapPool p = SwapPool(LibClone.clone(address(poolImpl)));
        p.initialize(
            "P",
            "P",
            18,
            owner,
            address(feePolicy),
            address(0),
            address(registry),
            address(limiter),
            address(0),
            false,
            address(pfc)
        );
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000); // 1%

        b.mint(address(p), 100_000e18);
        a.mint(attacker, 1_000e18);

        vm.startPrank(attacker);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 1_000e18);
        vm.stopPrank();

        assertEq(b.balanceOf(attacker), 990e18, "user still charged the 1% fee");
        assertEq(p.fees(address(b)), 0, "but no fee was ever recorded");
    }

    // =====================================================================
    // F-08  In coupled mode accumulated fees double as swap liquidity, so
    //       fees[] can exceed the balance and full fee collection reverts.
    // =====================================================================
    function test_POC_F08_coupledMode_feesOverAccrue() public {
        AudERC20 a = new AudERC20("A", "A", 18);
        AudERC20 b = new AudERC20("B", "B", 18);

        SwapPool p = _pool(address(0), false); // feesDecoupled = false
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000); // 1%

        b.mint(address(p), 100e18);
        a.mint(attacker, 200e18);

        vm.startPrank(attacker);
        a.approve(address(p), type(uint256).max);
        p.withdraw(address(b), address(a), 100e18); // drains to the fee reserve
        p.withdraw(address(b), address(a), 1e18); // spends part of the reserve
        vm.stopPrank();

        assertGt(p.fees(address(b)), b.balanceOf(address(p)), "recorded fees exceed the balance");

        vm.prank(owner);
        vm.expectRevert();
        p.withdraw(address(b)); // full collection can never succeed
    }

    // =====================================================================
    // H-1 (FIXED)  The bounded overload lets a caller pin the settlement
    //              price and an expiry, so a price move between quoting and
    //              execution reverts instead of settling silently.
    // =====================================================================
    function test_H1_boundedSwap_revertsWhenPriceMovesAfterQuoting() public {
        AudERC20 a = new AudERC20("A", "A", 18);
        AudERC20 b = new AudERC20("B", "B", 18);

        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000); // 1%

        b.mint(address(p), 100_000e18);
        a.mint(user, 1_000e18);

        uint256 quoted = p.getAmountOut(address(b), address(a), 1_000e18);
        assertEq(quoted, 990e18, "user sees 990 when signing");

        // The price moves before the transaction lands.
        feePolicy.setFee(address(a), address(b), 900_000);

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.InsufficientOutput.selector);
        p.withdraw(address(b), address(a), 1_000e18, user, quoted, block.timestamp + 1);
        vm.stopPrank();

        assertEq(a.balanceOf(user), 1_000e18, "input untouched");
        assertEq(b.balanceOf(user), 0, "nothing settled at the worse price");
    }

    function test_H1_boundedSwap_settlesAtOrAboveTheFloor() public {
        AudERC20 a = new AudERC20("A", "A", 18);
        AudERC20 b = new AudERC20("B", "B", 18);

        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        feePolicy.setFee(address(a), address(b), 10_000); // 1%

        b.mint(address(p), 100_000e18);
        a.mint(user, 1_000e18);

        uint256 quoted = p.getAmountOut(address(b), address(a), 1_000e18);

        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        uint256 got = p.withdraw(address(b), address(a), 1_000e18, user, quoted, block.timestamp + 1);
        vm.stopPrank();

        assertEq(got, quoted, "getAmountOut is what the swap actually pays");
        assertEq(b.balanceOf(user), quoted);
    }

    function test_H1_boundedSwap_expiredDeadlineReverts() public {
        AudERC20 a = new AudERC20("A", "A", 18);
        AudERC20 b = new AudERC20("B", "B", 18);

        SwapPool p = _pool(address(0), false);
        _allow(p, address(a), type(uint256).max);
        _allow(p, address(b), type(uint256).max);
        b.mint(address(p), 100_000e18);
        a.mint(user, 1_000e18);

        vm.warp(1_000_000);
        vm.startPrank(user);
        a.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.Expired.selector);
        p.withdraw(address(b), address(a), 1_000e18, user, 0, block.timestamp - 1);
        vm.stopPrank();

        assertEq(a.balanceOf(user), 1_000e18, "a stale transaction cannot settle");
    }

    // =====================================================================
    // F-11  _swap has no minimum-output check, so a quote that truncates to
    //       zero consumes the caller's input and transfers nothing back.
    // =====================================================================
    function test_L5_zeroQuoteRevertsInsteadOfConsumingInput() public {
        AudERC20 big = new AudERC20("Big", "BIG", 18);
        AudERC20 small = new AudERC20("Small", "SML", 6);
        DecimalQuoter dq = new DecimalQuoter();

        SwapPool p = _pool(address(dq), false);
        _allow(p, address(big), type(uint256).max);
        _allow(p, address(small), type(uint256).max);
        feePolicy.setFee(address(big), address(small), 10_000);

        small.mint(address(p), 1_000e6);
        big.mint(attacker, 1e18);

        // Anything below 1e12 wei of an 18-decimal input rounds to 0 of a
        // 6-decimal output. The quote no longer reports that as a valid 0.
        uint256 dust = 999_999_999_999;
        vm.expectRevert(SwapPool.InsufficientOutput.selector);
        p.getAmountOut(address(small), address(big), dust);

        vm.startPrank(attacker);
        big.approve(address(p), type(uint256).max);
        vm.expectRevert(SwapPool.InsufficientOutput.selector);
        p.withdraw(address(small), address(big), dust);
        vm.stopPrank();

        assertEq(big.balanceOf(attacker), 1e18, "input was not taken");
        assertEq(small.balanceOf(attacker), 0);

        // One wei more of input clears the truncation and settles normally.
        vm.startPrank(attacker);
        p.withdraw(address(small), address(big), dust + 1);
        vm.stopPrank();
        assertGt(small.balanceOf(attacker), 0, "a quote that does not truncate still works");
    }

    // =====================================================================
    // F-10  getScale accepts up to 77 decimals but the surrounding
    //       multiplications overflow well before that, so the guard never
    //       produces its InvalidDecimals error.
    // =====================================================================
    function test_POC_F10_getScale_boundIsUnreachable() public {
        AudERC20 normal = new AudERC20("N", "N", 6);
        AudERC20 wide = new AudERC20("W", "W", 70); // < 77, so getScale allows it
        MockChainlinkAggregator fn = new MockChainlinkAggregator(8, "N/USD", 1e8);
        MockChainlinkAggregator fw = new MockChainlinkAggregator(8, "W/USD", 1e8);

        OracleQuoter q = _oracleQuoter(address(normal));
        vm.startPrank(owner);
        q.setOracle(address(normal), address(fn));
        q.setOracle(address(wide), address(fw));
        vm.stopPrank();

        // Reverts with an arithmetic panic, never with InvalidDecimals(70).
        vm.expectRevert(stdError.arithmeticError);
        q.valueFor(address(wide), address(normal), 1e6);
    }
}

// =====================================================================
// Oracle-side findings. Split into a second contract so the staleness
// tests can control block.timestamp without disturbing the pool fixtures.
// =====================================================================
contract AuditOraclePoCTest is Test {
    uint256 constant PPM = 1_000_000;
    uint256 constant T0 = 1_700_000_000;

    OracleQuoter quoterImpl;
    OracleQuoter q;

    AudTokenMeta t6;
    AudTokenMeta t6b;
    AudTokenMeta t18;

    AudAgg feedFast; // oracle for t6 / t18
    AudAgg feedSlow; // oracle for t6b

    address owner = makeAddr("quoterOwner");

    function setUp() public {
        vm.warp(T0);
        quoterImpl = new OracleQuoter();
        q = OracleQuoter(LibClone.clone(address(quoterImpl)));

        t6 = new AudTokenMeta(6);
        t6b = new AudTokenMeta(6);
        t18 = new AudTokenMeta(18);

        feedFast = new AudAgg(8, 1e8);
        feedSlow = new AudAgg(8, 1e8);

        q.initialize(owner, address(t18));
        vm.startPrank(owner);
        q.setOracle(address(t6), address(feedFast));
        q.setOracle(address(t18), address(feedFast));
        q.setOracle(address(t6b), address(feedSlow));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // M-1 (FIXED) The corrected stage order also holds for identical token
    // decimals and extreme rate ratios.
    // -----------------------------------------------------------------
    function test_M1_roundtripHoldsWithIdenticalDecimals() public {
        AudTokenMeta cheap = new AudTokenMeta(6);
        AudAgg microFeed = new AudAgg(8, 100); // price 1e-6, same 8 decimals

        vm.startPrank(owner);
        q.setOracle(address(cheap), address(microFeed));
        q.setMultiplier(950_000);
        vm.stopPrank();

        uint256 needed = q.reverseValueFor(address(t6), address(cheap), 1);
        assertGe(q.valueFor(address(t6), address(cheap), needed), 1, "same-decimal roundtrip holds");
    }

    /// The recommended fix — undo the multiplier before inverting the rate —
    /// restores the invariant for every amount the current order breaks.
    function test_M1_correctedOrderIsUsedForEveryAmount() public {
        vm.prank(owner);
        q.setMultiplier(950_000);

        uint256 A = uint256(1e8) * 1e6 * 1e8; // inRate * outScale * outRateScale
        uint256 B = uint256(1e8) * 1e18 * 1e8; // inRateScale * inScale * outRate

        for (uint256 y = 1; y <= 22; y++) {
            uint256 actual = q.reverseValueFor(address(t6), address(t18), y);
            uint256 corrected = FixedPointMathLib.fullMulDivUp(FixedPointMathLib.fullMulDivUp(y, PPM, 950_000), B, A);
            assertEq(actual, corrected, "implementation uses corrected order");
            assertGe(q.valueFor(address(t6), address(t18), actual), y, "corrected order holds");
        }
    }

    // -----------------------------------------------------------------
    // M-4 (FIXED) Feed-specific bounds allow heterogeneous heartbeats while
    //      the global maxStaleness remains a backward-compatible fallback.
    // -----------------------------------------------------------------
    function test_M4_feedSpecificStalenessSupportsHeterogeneousFeeds() public {
        vm.startPrank(owner);
        q.setOracle(address(t6), address(feedFast), 1 hours);
        q.setOracle(address(t18), address(feedFast), 1 hours);
        q.setOracle(address(t6b), address(feedSlow), 24 hours);
        vm.stopPrank();

        // A 1-hour feed that has been dead for 23 hours is rejected even
        // though the backward-compatible global fallback is one day.
        feedFast.setUpdatedAt(T0 - 23 hours);
        feedSlow.setUpdatedAt(T0 - 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(OracleQuoter.StaleOraclePrice.selector, address(feedFast)));
        q.valueFor(address(t6b), address(t6), 1e6);

        // The same quoter still accepts a healthy 24-hour feed updated two
        // hours ago while enforcing the fast feed's tighter bound.
        feedFast.setUpdatedAt(T0 - 30 minutes);
        feedSlow.setUpdatedAt(T0 - 2 hours);
        assertEq(q.valueFor(address(t6b), address(t6), 1e6), 1e6);
    }

    // -----------------------------------------------------------------
    // L-4  A feed reporting a future timestamp underflows inside the try
    //      success block, which catch cannot reach.
    // -----------------------------------------------------------------
    function test_POC_L4_updatedAtInFuture_panicsInsteadOfNamedError() public {
        feedFast.setUpdatedAt(T0 + 100);
        vm.expectRevert(stdError.arithmeticError);
        q.valueFor(address(t6b), address(t6), 1e6);
    }

    // -----------------------------------------------------------------
    // L-7  maxStaleness == 0 bricks all quoting, and that is exactly what
    //      an in-place upgrade reads from the slot that predates it.
    // -----------------------------------------------------------------
    function test_POC_L7_maxStalenessZero_bricksQuoting() public {
        vm.prank(owner);
        q.setMaxStaleness(0); // accepted, no validation

        assertEq(q.valueFor(address(t6b), address(t6), 1e6), 1e6, "same second still works");

        vm.warp(T0 + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleQuoter.StaleOraclePrice.selector, address(feedFast)));
        q.valueFor(address(t6b), address(t6), 1e6);
    }

    function test_POC_L7_upgradeInPlace_readsZeroStaleness() public {
        // Confirm the layout: maxStaleness was appended at slot 2 in 14dda31,
        // multiplier at slot 3 in b3e4b94.
        assertEq(uint256(vm.load(address(q), bytes32(uint256(2)))), 86400, "slot 2 is maxStaleness");
        assertEq(uint256(vm.load(address(q), bytes32(uint256(3)))), 0, "slot 3 is multiplier");

        // Simulate a proxy initialized under d909ed8 (oracles, baseCurrency
        // only) and then upgraded in place to the current implementation.
        vm.store(address(q), bytes32(uint256(2)), bytes32(uint256(0)));
        vm.warp(T0 + 1);

        // multiplier == 0 has a documented fallback; maxStaleness == 0 has none.
        vm.expectRevert(abi.encodeWithSelector(OracleQuoter.StaleOraclePrice.selector, address(feedFast)));
        q.valueFor(address(t6b), address(t6), 1e6);
    }

    function test_POC_L7_unboundedStaleness_acceptsNeverUpdatedFeed() public {
        feedFast.setUpdatedAt(0); // round never completed

        vm.expectRevert(abi.encodeWithSelector(OracleQuoter.StaleOraclePrice.selector, address(feedFast)));
        q.valueFor(address(t6b), address(t6), 1e6);

        // "Disabling" staleness also disables the only guard against updatedAt == 0.
        vm.prank(owner);
        q.setMaxStaleness(type(uint256).max);
        assertEq(q.valueFor(address(t6b), address(t6), 1e6), 1e6, "never-updated feed now priced");
    }

    // -----------------------------------------------------------------
    // L-8  initialize accepts owner == address(0) and consumes the
    //      initializer, leaving the instance permanently unadministrable.
    // -----------------------------------------------------------------
    function test_POC_L8_initializeOwnerZero_bricksQuoter() public {
        OracleQuoter fresh = OracleQuoter(LibClone.clone(address(quoterImpl)));
        fresh.initialize(address(0), address(t18)); // baseCurrency is checked, owner is not
        assertEq(fresh.owner(), address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        fresh.setOracle(address(t6), address(feedFast));
    }

    function test_POC_L8_initializeOwnerZero_locksPoolAdmin() public {
        SwapPool impl = new SwapPool();
        SwapPool p = SwapPool(LibClone.clone(address(impl)));
        p.initialize(
            "P", "P", 18, address(0), address(0), makeAddr("fee"), address(0), address(0), address(0), false, address(0)
        );
        assertEq(p.owner(), address(0));

        // Swaps still work, but no fee can ever be collected and no setter
        // can ever be called again.
        vm.expectRevert(Ownable.Unauthorized.selector);
        p.withdraw(makeAddr("token"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        p.setQuoter(address(1));
    }

    // -----------------------------------------------------------------
    // I-1  supportsInterface reports a bare selector as an interface ID,
    //      omits the real IQuoter ID, and claims a wrong ERC-173 ID.
    // -----------------------------------------------------------------
    function test_POC_I1_supportsInterface_reportsWrongIds() public view {
        bytes4 valueForSel = bytes4(keccak256("valueFor(address,address,uint256)"));
        bytes4 reverseSel = bytes4(keccak256("reverseValueFor(address,address,uint256)"));

        // 0xdbb21d40 is only the valueFor selector — the legacy one-method ID.
        assertEq(valueForSel, bytes4(0xdbb21d40));
        assertEq(reverseSel, bytes4(0x56558fc8));

        // The real ERC-165 ID of the current two-method IQuoter.
        assertEq(type(IQuoter).interfaceId, valueForSel ^ reverseSel);
        assertEq(type(IQuoter).interfaceId, bytes4(0x8de79288));
        assertFalse(q.supportsInterface(0x8de79288), "real IQuoter ID not advertised");

        // ERC-173 is implemented via solady Ownable but not advertised.
        bytes4 erc173 = bytes4(keccak256("owner()")) ^ bytes4(keccak256("transferOwnership(address)"));
        assertEq(erc173, bytes4(0x7f5828d0));
        assertFalse(q.supportsInterface(0x7f5828d0), "canonical ERC-173 ID not advertised");
        assertEq(q.owner(), owner, "yet ERC-173 owner() works");

        // 0x9493f8b2, commented "ERC173" in RelativeQuoter, is not ERC-173.
        assertTrue(q.supportsInterface(0x9493f8b2));
        assertTrue(bytes4(0x9493f8b2) != erc173);
    }

    // -----------------------------------------------------------------
    // I-5  try/catch cannot catch return-data decoding failures, so the
    //      OracleCallFailed / TokenCallFailed wrappers never fire for the
    //      codeless-address misconfiguration they exist to report.
    // -----------------------------------------------------------------
    function test_POC_I5_codelessOracle_namedErrorUnreachable() public {
        vm.prank(owner);
        q.setOracle(address(t6), makeAddr("notAContract")); // no validation

        try q.valueFor(address(t6b), address(t6), 1e6) returns (uint256) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0, "bare revert, not OracleCallFailed");
        }
    }

    function test_POC_I5_codelessToken_namedErrorUnreachable() public {
        address notAToken = makeAddr("notAToken");
        vm.prank(owner);
        q.setOracle(notAToken, address(feedFast));

        try q.valueFor(notAToken, address(t6), 1e6) returns (uint256) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0, "bare revert, not TokenCallFailed");
        }
    }
}

// --------------------------------------------------------------------- mocks

contract AudTokenMeta {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }

    function name() external pure returns (string memory) {
        return "Aud";
    }

    function symbol() external pure returns (string memory) {
        return "AUD";
    }
}

/// Chainlink aggregator mock with a settable updatedAt.
contract AudAgg {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract AudERC20 is IERC20 {
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

/// Burns `feeBps10k / 10_000` of every transfer.
contract AudFotERC20 is AudERC20 {
    uint256 public immutable feeBps10k;

    constructor(string memory n, string memory s, uint8 d, uint256 fee) AudERC20(n, s, d) {
        feeBps10k = fee;
    }

    function transferFrom(address f, address t, uint256 v) external override returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        uint256 burned = (v * feeBps10k) / 10_000;
        balanceOf[f] -= v;
        balanceOf[t] += v - burned;
        return true;
    }
}

/// Reports success on transferFrom without moving anything.
contract AudLyingERC20 is AudERC20 {
    constructor(string memory n, string memory s, uint8 d) AudERC20(n, s, d) {}

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return true;
    }
}

/// Moves tokens but returns no data at all (non-conforming, e.g. old USDT forks).
contract AudVoidERC20 {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external {}

    function transfer(address, uint256) external {}
}

/// Calls back into `hook` on every transfer (ERC-777 / ERC-1363 style).
contract AudHookERC20 is AudERC20 {
    address public hook;

    constructor(string memory n, string memory s, uint8 d) AudERC20(n, s, d) {}

    function setHook(address h) external {
        hook = h;
    }

    function transfer(address to, uint256 v) external override returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        if (hook != address(0)) AudReenter(hook).onTokenTransfer();
        return true;
    }
}

contract AudReenter {
    SwapPool immutable pool;
    address immutable tokenOut;
    address immutable tokenIn;
    uint256 innerAmount;
    bool entered;

    constructor(SwapPool p, address out, address inn) {
        pool = p;
        tokenOut = out;
        tokenIn = inn;
    }

    function attack(uint256 outer, uint256 inner) external {
        innerAmount = inner;
        AudERC20(tokenIn).approve(address(pool), type(uint256).max);
        pool.withdraw(tokenOut, tokenIn, outer);
    }

    function onTokenTransfer() external {
        if (entered || innerAmount == 0) return;
        entered = true;
        pool.withdraw(tokenOut, tokenIn, innerAmount);
    }
}

contract AudRegistry {
    mapping(address => bool) private allowed;

    function add(address t) external {
        allowed[t] = true;
    }

    function have(address t) external view returns (bool) {
        return allowed[t];
    }
}

contract AudLimiter is ILimiter {
    mapping(address => mapping(address => uint256)) private limits;

    function setLimit(address t, address h, uint256 v) external {
        limits[t][h] = v;
    }

    function limitOf(address t, address h) external view returns (uint256) {
        return limits[t][h];
    }
}

contract AudFeePolicy is IFeePolicy {
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

contract AudPfc is IProtocolFeeController {
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
