// SPDX-License-Identifier: AGPL-3.0
// Gap-filling pass: stateful invariant fuzzing, reentrancy on surfaces the
// targeted PoCs did not reach, and behavioural assertions for the handful of
// external functions no other audit test touches.
//
// The SwapPool invariant exercises swaps, fee collection, and emergency
// liquidity withdrawals in decoupled mode. Reentrancy and reserved-fee
// withdrawals are fixed; coupled-mode fee re-lending remains outside the model.
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SwapPool} from "../../src/SwapPool.sol";
import {TokenUniqueSymbolIndex} from "../../src/TokenUniqueSymbolIndex.sol";
import {OracleQuoter} from "../../src/OracleQuoter.sol";
import {EthFaucet} from "../../src/EthFaucet.sol";
import {FeePolicy} from "../../src/FeePolicy.sol";
import {ProtocolFeeController} from "../../src/ProtocolFeeController.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {ILimiter} from "../../src/interfaces/ILimiter.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";

// ---------------------------------------------------------------- invariant

contract InvERC20 is IERC20 {
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

contract InvFeePolicy is IFeePolicy {
    uint256 public ppm = 30_000;

    function setPpm(uint256 v) external {
        ppm = v;
    }

    function getFee(address, address) external view returns (uint256) {
        return ppm;
    }

    function isActive() external pure returns (bool) {
        return true;
    }
}

contract InvPfc is IProtocolFeeController {
    function getProtocolFee() external pure returns (uint256) {
        return 50_000;
    }

    function getProtocolFeeRecipient() external pure returns (address) {
        return address(0xFEE);
    }

    function isActive() external pure returns (bool) {
        return true;
    }
}

/// Bounded action surface, including the M-6 emergency-withdrawal path.
contract PoolHandler is Test {
    SwapPool public pool;
    InvERC20 public a;
    InvERC20 public b;
    InvFeePolicy public fp;
    address public owner;

    uint256 public swaps;
    uint256 public collects;

    constructor(SwapPool p, InvERC20 a_, InvERC20 b_, InvFeePolicy fp_, address owner_) {
        pool = p;
        a = a_;
        b = b_;
        fp = fp_;
        owner = owner_;
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
    }

    function swapAtoB(uint256 seed) external {
        uint256 amt = bound(seed, 1, 50e18);
        a.mint(address(this), amt);
        try pool.withdraw(address(b), address(a), amt) {
            swaps++;
        } catch {}
    }

    function swapBtoA(uint256 seed) external {
        uint256 amt = bound(seed, 1, 50e18);
        b.mint(address(this), amt);
        try pool.withdraw(address(a), address(b), amt) {
            swaps++;
        } catch {}
    }

    function depositA(uint256 seed) external {
        uint256 amt = bound(seed, 1, 50e18);
        a.mint(address(this), amt);
        try pool.deposit(address(a), amt) {} catch {}
    }

    function collectAll(bool which) external {
        address t = which ? address(a) : address(b);
        vm.prank(owner);
        try pool.withdraw(t) {
            collects++;
        } catch {}
    }

    function collectSome(uint256 seed, bool which) external {
        address t = which ? address(a) : address(b);
        uint256 v = bound(seed, 0, pool.fees(t));
        vm.prank(owner);
        try pool.withdraw(t, v) {
            collects++;
        } catch {}
    }

    function withdrawLiquidity(uint256 seed, bool which) external {
        InvERC20 token = which ? a : b;
        uint256 balance = token.balanceOf(address(pool));
        uint256 reserved = pool.fees(address(token));
        uint256 available = balance > reserved ? balance - reserved : 0;
        uint256 value = bound(seed, 0, available);
        vm.prank(owner);
        try pool.withdrawLiquidity(address(token), address(this), value) {} catch {}
    }

    function changeFee(uint256 seed) external {
        fp.setPpm(bound(seed, 0, 900_000));
    }
}

contract AuditInvariantTest is Test {
    SwapPool pool;
    InvERC20 a;
    InvERC20 b;
    InvFeePolicy fp;
    PoolHandler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        a = new InvERC20();
        b = new InvERC20();
        fp = new InvFeePolicy();

        SwapPool impl = new SwapPool();
        pool = SwapPool(LibClone.clone(address(impl)));
        pool.initialize(
            "P",
            "P",
            18,
            owner,
            address(fp),
            makeAddr("feeAddress"),
            address(0), // no registry: keeps the action surface open
            address(0), // no limiter
            address(0), // 1:1 quoter, so pricing is not the variable under test
            true, // feesDecoupled: excludes L-2
            address(new InvPfc())
        );

        a.mint(address(pool), 10_000e18);
        b.mint(address(pool), 10_000e18);

        handler = new PoolHandler(pool, a, b, fp, owner);
        targetContract(address(handler));
    }

    /// M-2 and M-6 are exercised as fixed paths; coupled-mode L-2 is excluded.
    function invariant_feesNeverExceedBalance() public view {
        assertLe(pool.fees(address(a)), a.balanceOf(address(pool)), "fees[a] > balance");
        assertLe(pool.fees(address(b)), b.balanceOf(address(pool)), "fees[b] > balance");
    }

    /// Nothing should be able to make the pool hand out more than it holds.
    function invariant_poolNeverOwesMoreThanItHolds() public view {
        uint256 owedA = pool.fees(address(a));
        uint256 owedB = pool.fees(address(b));
        assertGe(a.balanceOf(address(pool)) + b.balanceOf(address(pool)), owedA + owedB, "aggregate insolvency");
    }
}

// -------------------------------------------- reentrancy on registry surfaces

contract ReentrantSymbolToken {
    TokenUniqueSymbolIndex idx;
    bool entered;
    string public sym = "AAA";

    function setIndex(TokenUniqueSymbolIndex i) external {
        idx = i;
    }

    /// Re-enters the index while it is being read.
    function symbol() external returns (string memory) {
        if (!entered) {
            entered = true;
            try idx.register(address(this)) {} catch {}
        }
        return sym;
    }
}

contract AuditGapFillTest is Test {
    address owner = makeAddr("owner");

    /// The external `symbol()` read in register() happens BEFORE the state
    /// write in _register(), which is checks-interactions-effects. Access
    /// control is what closes it: the re-entrant caller is the token, not a
    /// writer, so the nested register() reverts Access and no second slot is
    /// created. Verifying this because M-11's corruption would otherwise be
    /// reachable in ONE writer action instead of two.
    function test_registerReentrancy_isBlockedByAccessControl_holds() public {
        TokenUniqueSymbolIndex impl = new TokenUniqueSymbolIndex();
        TokenUniqueSymbolIndex idx = TokenUniqueSymbolIndex(LibClone.clone(address(impl)));
        idx.initialize(owner, new address[](0), new bytes32[](0));

        ReentrantSymbolToken t = new ReentrantSymbolToken();
        t.setIndex(idx);

        vm.prank(owner);
        idx.register(address(t));

        // Exactly one slot, not two: the nested register() was rejected.
        assertEq(idx.entryCount(), 1, "reentrancy did not create a second slot");
        assertTrue(idx.have(address(t)));
        assertEq(idx.entry(0), address(t));
    }

    // ----------------------------------------------------------------------
    // Behavioural assertions for the external functions no other audit test
    // reaches, so the surface is covered rather than assumed.
    // ----------------------------------------------------------------------

    function test_removeOracle_bricksQuotesForThatToken_isCorrect() public {
        OracleQuoter qImpl = new OracleQuoter();
        OracleQuoter q = OracleQuoter(LibClone.clone(address(qImpl)));
        q.initialize(owner, address(0xBEEF));

        GapToken t1 = new GapToken();
        GapToken t2 = new GapToken();
        GapFeed f = new GapFeed();

        vm.startPrank(owner);
        q.setOracle(address(t1), address(f));
        q.setOracle(address(t2), address(f));
        vm.stopPrank();

        assertGt(q.valueFor(address(t2), address(t1), 1e18), 0);

        vm.prank(owner);
        q.removeOracle(address(t1));

        // Fails closed, with the named error. Owner-only, so availability only.
        vm.expectRevert(abi.encodeWithSelector(OracleQuoter.OracleNotSet.selector, address(t1)));
        q.valueFor(address(t2), address(t1), 1e18);
    }

    function test_setProtocolFeeRecipient_validatesAndIsOwnerOnly_isCorrect() public {
        ProtocolFeeController impl = new ProtocolFeeController();
        ProtocolFeeController pfc = ProtocolFeeController(LibClone.clone(address(impl)));
        pfc.initialize(owner, 10_000, makeAddr("r1"));

        assertEq(pfc.getProtocolFeeRecipient(), makeAddr("r1"));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        pfc.setProtocolFeeRecipient(makeAddr("r2"));

        vm.prank(owner);
        vm.expectRevert(ProtocolFeeController.InvalidRecipient.selector);
        pfc.setProtocolFeeRecipient(address(0));

        vm.prank(owner);
        pfc.setProtocolFeeRecipient(makeAddr("r2"));
        assertEq(pfc.getProtocolFeeRecipient(), makeAddr("r2"));
    }

    function test_getDefaultFee_tracksSetter_isCorrect() public {
        FeePolicy impl = new FeePolicy();
        FeePolicy fp = FeePolicy(LibClone.clone(address(impl)));
        fp.initialize(owner, 12_345);
        assertEq(fp.getDefaultFee(), 12_345);
        vm.prank(owner);
        fp.setDefaultFee(999_999);
        assertEq(fp.getDefaultFee(), 999_999);
        assertEq(fp.getDefaultFee(), fp.defaultFee(), "getter agrees with the public variable");
    }

    function test_tokenAmount_isTheDripAmount_isCorrect() public {
        EthFaucet impl = new EthFaucet();
        EthFaucet f = EthFaucet(payable(LibClone.clone(address(impl))));
        f.initialize(owner, 7 ether);
        assertEq(f.tokenAmount(), 7 ether, "returns the configured drip amount");
        vm.prank(owner);
        f.setAmount(3 ether);
        assertEq(f.tokenAmount(), 3 ether, "tracks setAmount");
    }
}

contract GapToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract GapFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}
