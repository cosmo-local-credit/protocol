// SPDX-License-Identifier: AGPL-3.0
// Proof-of-concept exploits and verification tests for RelativeQuoter,
// DecimalQuoter, FeePolicy, ProtocolFeeController and Limiter.
// Findings are written up in audit/AUDIT.md.
//
// A PASSING test whose name describes a defect means the defect is PRESENT.
// Tests suffixed `_holds` / `_isCorrect` assert properties that do hold and
// record candidates that were investigated and discarded.
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {RelativeQuoter} from "../../src/RelativeQuoter.sol";
import {DecimalQuoter} from "../../src/DecimalQuoter.sol";
import {FeePolicy} from "../../src/FeePolicy.sol";
import {ProtocolFeeController} from "../../src/ProtocolFeeController.sol";
import {Limiter} from "../../src/Limiter.sol";

contract AuditPoCQuoterTest is Test {
    uint256 constant PPM = 1_000_000;

    RelativeQuoter rqImpl;
    RelativeQuoter rq;
    DecimalQuoter dq;
    FeePolicy fpImpl;
    ProtocolFeeController pfcImpl;
    Limiter limImpl;

    QtToken t18;
    QtToken t6;

    address owner = makeAddr("owner");

    function setUp() public {
        rqImpl = new RelativeQuoter();
        rq = RelativeQuoter(LibClone.clone(address(rqImpl)));
        rq.initialize(owner);

        dq = new DecimalQuoter();
        fpImpl = new FeePolicy();
        pfcImpl = new ProtocolFeeController();
        limImpl = new Limiter();

        t18 = new QtToken(18);
        t6 = new QtToken(6);
    }

    // =================================================================
    // M-8 (FIXED) RelativeQuoter combines decimal scaling with rate conversion
    // before truncation, and its reverse preserves the IQuoter round-trip.
    // =================================================================
    function test_relativeQuoter_roundtripInvariant_holds() public {
        // in = 18 decimals rated 3.0, out = 6 decimals rated 1.0
        vm.startPrank(owner);
        rq.setPriceIndexValue(address(t18), 3_000_000);
        rq.setPriceIndexValue(address(t6), 1_000_000);
        vm.stopPrank();

        uint256 needed = rq.reverseValueFor(address(t6), address(t18), 1);
        uint256 delivered = rq.valueFor(address(t6), address(t18), needed);

        assertEq(needed, 333_333_333_334, "reverse asks for 3.33e11 wei");
        assertGe(delivered, 1, "IQuoter round-trip covers the request");
    }

    function test_relativeQuoter_hasNoRoundtripViolations() public {
        vm.startPrank(owner);
        rq.setPriceIndexValue(address(t18), 3_000_000);
        rq.setPriceIndexValue(address(t6), 1_000_000);
        vm.stopPrank();

        uint256 violations;
        for (uint256 x = 1; x <= 30; x++) {
            if (rq.valueFor(address(t6), address(t18), rq.reverseValueFor(address(t6), address(t18), x)) < x) {
                violations++;
            }
        }
        assertEq(violations, 0, "no request size under-delivers");
    }

    /// Decimal scaling no longer discards the input remainder before applying
    /// a large exchange-rate ratio.
    function test_relativeQuoter_preservesCrossDecimalPrecision() public {
        // in = 18 decimals rated 1e6x the reference, out = 6 decimals at 1.0
        vm.startPrank(owner);
        rq.setPriceIndexValue(address(t18), 1_000_000_000_000); // 1e6 x
        rq.setPriceIndexValue(address(t6), 1_000_000);
        vm.stopPrank();

        // Just under two whole 18-decimal units.
        uint256 amountIn = 2e12 - 1;

        uint256 got = rq.valueFor(address(t6), address(t18), amountIn);
        // Correct value, multiplying before dividing:
        //   amountIn * inRate / (d * outRate) = (2e12-1) * 1e12 / (1e12 * 1e6)
        uint256 exact = (amountIn * 1_000_000_000_000) / (1e12 * 1_000_000);

        assertEq(exact, 1_999_999, "exact: 1.999999 output tokens");
        assertEq(got, exact, "combined mulDiv preserves the exact floor");
    }

    /// DecimalQuoter's reverse IS a correct inverse in both directions —
    /// investigated and discarded.
    function test_decimalQuoter_roundtrip_holds() public view {
        for (uint256 x = 1; x <= 50; x++) {
            // 18-decimal in, 6-decimal out
            uint256 a = dq.reverseValueFor(address(t6), address(t18), x);
            assertGe(dq.valueFor(address(t6), address(t18), a), x, "18->6 holds");
            // 6-decimal in, 18-decimal out
            uint256 b = dq.reverseValueFor(address(t18), address(t6), x * 1e12);
            assertGe(dq.valueFor(address(t18), address(t6), b), x * 1e12, "6->18 holds");
        }
    }

    // =================================================================
    // FeePolicy cannot express a zero fee for a pair: storing 0 is
    // indistinguishable from unset, so getFee silently returns defaultFee
    // while the emitted event claims the fee is 0.
    // =================================================================
    function test_POC_feePolicy_zeroPairFee_silentlyBecomesDefault() public {
        FeePolicy fp = FeePolicy(LibClone.clone(address(fpImpl)));
        fp.initialize(owner, 100_000); // 10 % default

        vm.prank(owner);
        fp.setPairFee(address(t18), address(t6), 0); // operator intends "free"

        assertEq(fp.getFee(address(t18), address(t6)), 100_000, "charges 10 %, not 0");
        assertEq(fp.calculateFee(address(t18), address(t6), 1_000e18), 100e18, "10 % of notional");

        // removePairFee is not an escape either — it also falls back to default.
        vm.prank(owner);
        fp.removePairFee(address(t18), address(t6));
        assertEq(fp.getFee(address(t18), address(t6)), 100_000, "still 10 %");
    }

    /// The event reports the state the operator asked for, not the state that
    /// results, so an indexer reconstructing fees from logs is wrong.
    function test_POC_feePolicy_zeroPairFee_eventContradictsState() public {
        FeePolicy fp = FeePolicy(LibClone.clone(address(fpImpl)));
        fp.initialize(owner, 100_000);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit PairFeeUpdated(address(t18), address(t6), 100_000, 0); // "new fee is 0"
        fp.setPairFee(address(t18), address(t6), 0);

        assertEq(fp.getFee(address(t18), address(t6)), 100_000, "but getFee says 100_000");
    }

    event PairFeeUpdated(address indexed tokenIn, address indexed tokenOut, uint256 oldFee, uint256 newFee);

    /// Pair fees are direction-scoped by a fixed-width encodePacked of two
    /// addresses, so no key collision is possible — investigated and discarded.
    function test_feePolicy_pairKey_hasNoCollision_holds() public {
        FeePolicy fp = FeePolicy(LibClone.clone(address(fpImpl)));
        fp.initialize(owner, 0);

        vm.startPrank(owner);
        fp.setPairFee(address(t18), address(t6), 10_000);
        fp.setPairFee(address(t6), address(t18), 20_000);
        vm.stopPrank();

        assertEq(fp.getFee(address(t18), address(t6)), 10_000);
        assertEq(fp.getFee(address(t6), address(t18)), 20_000, "directions stay independent");
    }

    // =================================================================
    // L-7 (FIXED): every proxied contract in this group rejects a zero owner
    // before consuming its initializer.
    // =================================================================
    function test_initializeOwnerZero_isRejectedByEveryProxiedContract() public {
        FeePolicy fp = FeePolicy(LibClone.clone(address(fpImpl)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        fp.initialize(address(0), 10_000);

        ProtocolFeeController pfc = ProtocolFeeController(LibClone.clone(address(pfcImpl)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        pfc.initialize(address(0), 10_000, makeAddr("recipient"));

        Limiter lim = Limiter(LibClone.clone(address(limImpl)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        lim.initialize(address(0));

        RelativeQuoter q = RelativeQuoter(LibClone.clone(address(rqImpl)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        q.initialize(address(0));
    }

    // =================================================================
    // RelativeQuoter reaches the token with `.call` rather than
    // `staticcall`, so reading `decimals()` hands an arbitrary token full
    // re-entrancy context, and a codeless token yields a bare revert
    // instead of the declared TokenCallFailed.
    // =================================================================
    function test_POC_relativeQuoter_decimalsIsNotStaticcall() public {
        QtReentrantToken hostile = new QtReentrantToken();

        vm.prank(owner);
        rq.setPriceIndexValue(address(hostile), PPM);

        rq.valueFor(address(hostile), address(t18), 1e18);
        assertTrue(hostile.wroteDuringDecimals(), "token mutated state while being read");
    }

    function test_POC_relativeQuoter_codelessToken_namedErrorUnreachable() public {
        address notAToken = makeAddr("notAToken");

        try rq.valueFor(notAToken, address(t18), 1e18) returns (uint256) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0, "bare revert, not TokenCallFailed");
        }
    }

    /// Limiter's extcodesize guard rejects a not-yet-deployed holder, which
    /// blocks configure-then-deploy against a deterministic address. SPEC
    /// documents this, so it is recorded here as expected behaviour rather
    /// than reported as a finding.
    function test_limiter_rejectsUndeployedHolder_isCorrect() public {
        Limiter lim = Limiter(LibClone.clone(address(limImpl)));
        lim.initialize(owner);

        vm.prank(owner);
        vm.expectRevert(Limiter.InvalidHolder.selector);
        lim.setLimitFor(address(t18), makeAddr("notYetDeployed"), type(uint256).max);
    }
}

// ------------------------------------------------------------------ mocks

contract QtToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// Writes to its own storage while being read, proving the call is not static.
contract QtReentrantToken {
    bool public wroteDuringDecimals;
    uint256 private counter;

    function decimals() external returns (uint8) {
        wroteDuringDecimals = true;
        counter++;
        return 18;
    }
}
