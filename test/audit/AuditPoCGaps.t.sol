// SPDX-License-Identifier: AGPL-3.0
// Proof-of-concept tests for the follow-up review ("gap sweep") that ran
// after the original 67-finding audit. Each test is named after the finding
// it demonstrates in audit/AUDIT.md (sections L-28 .. L-31 and I-13 .. I-16).
//
// A PASSING test whose name describes a defect means the defect is PRESENT:
// the assertions encode the broken behaviour, not the desired behaviour.
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SwapPool} from "../../src/SwapPool.sol";
import {EthFaucet} from "../../src/EthFaucet.sol";
import {PeriodSimple} from "../../src/PeriodSimple.sol";
import {GiftableToken} from "../../src/GiftableToken.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {ILimiter} from "../../src/interfaces/ILimiter.sol";
import {IFeePolicy} from "../../src/interfaces/IFeePolicy.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

contract AuditPoCGapsTest is Test {
    uint256 constant PPM = 1_000_000;

    SwapPool poolImpl;
    EthFaucet faucetImpl;
    PeriodSimple periodImpl;
    GiftableToken tokenImpl;

    GapRegistry registry;
    GapLimiter limiter;
    GapFeePolicy feePolicy;

    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");
    address attacker = makeAddr("attacker");

    function setUp() public {
        poolImpl = new SwapPool();
        faucetImpl = new EthFaucet();
        periodImpl = new PeriodSimple();
        tokenImpl = new GiftableToken();
        registry = new GapRegistry();
        limiter = new GapLimiter();
        feePolicy = new GapFeePolicy();
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
            address(0) // no protocol fee controller
        );
    }

    function _faucet(uint256 amount) internal returns (EthFaucet f) {
        f = EthFaucet(payable(LibClone.clone(address(faucetImpl))));
        f.initialize(owner, amount);
    }

    function _period(address poker, uint256 periodSecs) internal returns (PeriodSimple ps) {
        ps = PeriodSimple(LibClone.clone(address(periodImpl)));
        ps.initialize(owner, poker);
        vm.prank(owner);
        ps.setPeriod(periodSecs);
    }

    // =====================================================================
    // L-28  EthFaucet.giveTo(address(0)) burns ETH: no zero-recipient check.
    //       The unbounded loop variant is closed by the H-4 fix; what remains
    //       is one burn per period, and only where the operator's registry
    //       admits the zero address.
    // =====================================================================
    function test_POC_L28_ungatedLoopIsClosedByFailClosedGating() public {
        EthFaucet f = _faucet(0.5 ether);
        vm.deal(address(f), 5 ether);

        vm.expectRevert(EthFaucet.RegistryBackend.selector);
        f.giveTo(address(0));

        assertEq(address(f).balance, 5 ether, "nothing burned on an unconfigured faucet");
    }

    function test_POC_L28_giveToZeroAddress_burnsEth_periodGated() public {
        EthFaucet f = _faucet(0.5 ether);
        PeriodSimple ps = _period(address(f), 1 days);
        GapRegistry reg = new GapRegistry();
        reg.add(address(0)); // the operator's whitelist happens to contain 0
        vm.startPrank(owner);
        f.setPeriodChecker(address(ps));
        f.setRegistry(address(reg));
        vm.stopPrank();
        vm.deal(address(f), 5 ether);

        uint256 zeroBalBefore = address(0).balance;
        f.giveTo(address(0)); // burns once: poke(address(0)) succeeds
        assertEq(address(0).balance - zeroBalBefore, 0.5 ether, "burned despite the cooldown gate");

        // The cooldown now keys on address(0), so the burn is rate-limited —
        // but it repeats every period forever. Only the registry rejects 0.
        vm.expectRevert(EthFaucet.PeriodBackend.selector);
        f.giveTo(address(0));
        vm.warp(block.timestamp + 1 days + 1);
        f.giveTo(address(0)); // burns again
        assertEq(address(0).balance - zeroBalBefore, 1 ether, "burn repeats every period");
    }

    // =====================================================================
    // C-2 follow-on  Pricing a swap on the measured balance delta would let a
    //       tokenIn with a pre-transfer hook nest a second swap and be credited
    //       for the outer transfer twice. The reentrancy guard closes it.
    // =====================================================================
    function test_C2_nestedSwapWithHookedTokenIn_isBlocked() public {
        GapHookInERC20 tkn = new GapHookInERC20("Hook", "HK", 18);
        GapERC20 out = new GapERC20("Out", "OUT", 18);

        SwapPool p = _pool(address(0), false);
        registry.add(address(tkn));
        registry.add(address(out));
        limiter.setLimit(address(tkn), address(p), type(uint256).max);
        limiter.setLimit(address(out), address(p), type(uint256).max);
        out.mint(address(p), 100_000e18);

        GapSwapNest nest = new GapSwapNest(address(p), address(tkn), address(out));
        tkn.setHook(address(nest));
        tkn.mint(address(nest), 10_000e18);
        nest.approvePool();

        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        nest.attack(600e18, 600e18);

        assertEq(tkn.balanceOf(address(nest)), 10_000e18, "nothing was paid in");
        assertEq(out.balanceOf(address(nest)), 0, "nothing was credited out");
        assertEq(out.balanceOf(address(p)), 100_000e18, "pool intact");
    }

    /// The same token swapping normally, without nesting, still works.
    function test_C2_hookedTokenIn_singleSwapStillWorks() public {
        GapHookInERC20 tkn = new GapHookInERC20("Hook", "HK", 18);
        GapERC20 out = new GapERC20("Out", "OUT", 18);

        SwapPool p = _pool(address(0), false);
        registry.add(address(tkn));
        registry.add(address(out));
        limiter.setLimit(address(tkn), address(p), type(uint256).max);
        limiter.setLimit(address(out), address(p), type(uint256).max);
        out.mint(address(p), 100_000e18);

        GapSwapNest quiet = new GapSwapNest(address(p), address(tkn), address(out));
        tkn.mint(address(quiet), 10_000e18);
        quiet.approvePool();

        quiet.attack(600e18, 0); // hook unset, so nothing nests

        assertEq(tkn.balanceOf(address(quiet)), 9_400e18, "600 paid in");
        assertEq(out.balanceOf(address(quiet)), 600e18, "600 credited out, exactly once");
    }

    // =====================================================================
    // L-29 (FIXED)  The limiter cap is checked against the pre-transfer
    //       balance, so a tokenIn with a transfer hook used to nest deposits
    //       and leave the pool holding a multiple of the configured cap. The
    //       reentrancy guard on deposit() closes the nesting.
    // =====================================================================
    function test_L29_hookedTokenIn_nestedDeposit_isBlocked() public {
        GapHookInERC20 tkn = new GapHookInERC20("Hook", "HK", 18);

        SwapPool p = _pool(address(0), false);
        registry.add(address(tkn));
        limiter.setLimit(address(tkn), address(p), 1_000e18); // cap: 1 000

        // The attacker is a contract holding the whitelisted token; it
        // registers itself as the transfer hook (ERC-1820 style).
        GapDepositNest nest = new GapDepositNest(address(p), address(tkn));
        tkn.setHook(address(nest));
        tkn.mint(address(nest), 10_000e18);
        nest.approvePool();

        // One outer deposit of 600, whose hook nests a second 600 deposit while
        // the outer transferFrom is still in flight. Both checks would read the
        // pre-transfer balance (0) and both would pass: 0 + 600 <= 1000.
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        nest.attack(600e18, 600e18);

        assertEq(tkn.balanceOf(address(p)), 0, "nothing landed in the pool");

        // A plain, non-nested deposit is unaffected, and the cap is honoured.
        nest.deposit(600e18);
        assertEq(tkn.balanceOf(address(p)), 600e18);
        assertLe(tkn.balanceOf(address(p)), limiter.limitOf(address(tkn), address(p)), "cap respected");

        vm.expectRevert(SwapPool.LimitExceeded.selector);
        nest.deposit(500e18);
    }

    // =====================================================================
    // I-13  Ceiling-add overflow in the reverse quote paths: the forward
    //       direction handles a magnitude the reverse direction panics on.
    // =====================================================================
    function test_POC_I13_reverseNetToQuoted_ceilingAddOverflows() public {
        SwapPool p = _pool(address(0), false); // 1:1 quoter-less pricing
        feePolicy.setFee(address(1), address(2), 10_000); // 1% pool fee

        uint256 hugeOut = 1.2e65; // netOutput * PPM^2 (1e12) exceeds 2^256

        // Forward quote for the corresponding input works fine.
        uint256 out = p.getAmountOut(address(2), address(1), hugeOut);
        assertGt(out, 0, "forward direction handles the magnitude");

        // Reverse quote for the same magnitude panics: netOutput * PPM^2
        // overflows uint256 before the ceiling add is even reached.
        vm.expectRevert();
        p.getAmountIn(address(2), address(1), hugeOut);
    }

    // =====================================================================
    // I-14  A GiftableToken held by a SwapPool becomes permanently locked at
    //       expiry: withdrawLiquidity, fee collection and swaps all revert,
    //       and the dead balance keeps counting toward available liquidity.
    // =====================================================================
    function test_POC_I14_expiredVoucher_permanentlyLockedInPool() public {
        GiftableToken voucher = GiftableToken(LibClone.clone(address(tokenImpl)));
        voucher.initialize("Voucher", "VCH", 6, owner, block.timestamp + 30 days);

        SwapPool p = _pool(address(0), true); // decoupled, 1:1 quoter-less
        registry.add(address(voucher));
        limiter.setLimit(address(voucher), address(p), type(uint256).max);

        // Owner stocks the pool with vouchers; a swap accrues fees.
        vm.startPrank(owner);
        voucher.addWriter(owner);
        voucher.mintTo(address(p), 100_000e6);
        vm.stopPrank();

        GapERC20 pay = new GapERC20("Pay", "PAY", 6);
        registry.add(address(pay));
        limiter.setLimit(address(pay), address(p), type(uint256).max);
        feePolicy.setFee(address(pay), address(voucher), 10_000); // 1%

        // One ordinary swap, just to accrue 10e6 of reserved fees.
        address user = makeAddr("user");
        pay.mint(user, 1_000e6);
        vm.startPrank(user);
        pay.approve(address(p), type(uint256).max);
        p.withdraw(address(voucher), address(pay), 1_000e6);
        vm.stopPrank();
        assertEq(p.fees(address(voucher)), 10e6, "fees accrued");

        // Expire the voucher.
        vm.warp(block.timestamp + 31 days);

        // 1. The owner cannot rescue the dead inventory.
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        vm.prank(owner);
        p.withdrawLiquidity(address(voucher), owner, 1);

        // 2. The accrued fees can never be collected.
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        vm.prank(owner);
        p.withdraw(address(voucher));

        // 3. Even the owner cannot mint more — the supply is frozen.
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        vm.prank(owner);
        voucher.mintTo(user2, 1);
    }

    function test_POC_I14_expiredVoucher_swapRevertsAgainstFrozenBalance() public {
        GiftableToken voucher = GiftableToken(LibClone.clone(address(tokenImpl)));
        voucher.initialize("Voucher", "VCH", 6, owner, block.timestamp + 30 days);
        GapERC20 usdc = new GapERC20("USDC", "USDC", 6);

        SwapPool p = _pool(address(0), true);
        registry.add(address(voucher));
        registry.add(address(usdc));
        limiter.setLimit(address(voucher), address(p), type(uint256).max);
        limiter.setLimit(address(usdc), address(p), type(uint256).max);

        vm.startPrank(owner);
        voucher.addWriter(owner);
        voucher.mintTo(address(p), 100_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        // USDC -> expired voucher: quote and liquidity checks pass against the
        // frozen balance, then the payout transfer reverts TokenExpired.
        usdc.mint(user2, 1_000e6);
        vm.startPrank(user2);
        usdc.approve(address(p), type(uint256).max);
        vm.expectRevert(GiftableToken.TokenExpired.selector);
        p.withdraw(address(voucher), address(usdc), 1_000e6);
        vm.stopPrank();
    }

    address user2 = makeAddr("user2");

    // =====================================================================
    // I-15  withdrawLiquidity has no zero-address check on `to`: an operator
    //       typo burns pool assets instead of recovering them.
    // =====================================================================
    function test_POC_I15_withdrawLiquidity_toZeroAddress_burnsTokens() public {
        GapERC20 tkn = new GapERC20("T", "T", 18);
        SwapPool p = _pool(address(0), false);
        tkn.mint(address(p), 1_000e18);

        vm.prank(owner);
        p.withdrawLiquidity(address(tkn), address(0), 400e18); // succeeds

        assertEq(tkn.balanceOf(address(0)), 400e18, "tokens burned at the zero address");
        assertEq(tkn.balanceOf(address(p)), 600e18, "gone from the pool");
    }
}

// ---------------------------------------------------------------------------
// mocks
// ---------------------------------------------------------------------------

contract GapERC20 is IERC20 {
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

    function mint(address to, uint256 v) external {
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

/// ERC20 with a tokens-to-send hook (ERC-777/ERC-1820 style) that fires
/// BEFORE balances move inside transferFrom.
contract GapHookInERC20 is GapERC20 {
    address public hook;

    constructor(string memory n, string memory s, uint8 d) GapERC20(n, s, d) {}

    function setHook(address h) external {
        hook = h;
    }

    function transferFrom(address f, address t, uint256 v) external override returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        if (hook != address(0)) GapDepositNest(hook).onSend(); // pre-credit hook
        balanceOf[t] += v;
        return true;
    }
}

/// Nests a second SWAP while the outer transferFrom is in flight.
contract GapSwapNest {
    SwapPool immutable pool;
    address immutable token;
    address immutable out;
    uint256 nestedAmount;
    bool armed;

    constructor(address p, address t, address o) {
        pool = SwapPool(p);
        token = t;
        out = o;
    }

    function approvePool() external {
        GapERC20(token).approve(address(pool), type(uint256).max);
    }

    function attack(uint256 outer, uint256 inner) external {
        nestedAmount = inner;
        armed = true;
        pool.withdraw(out, token, outer);
    }

    function onSend() external {
        if (!armed) return;
        armed = false;
        pool.withdraw(out, token, nestedAmount);
    }
}

/// Nests a second deposit while the outer transferFrom is in flight.
/// The nest contract is itself the attacker: it holds the tokens and is the
/// msg.sender of both the outer and the nested deposit.
contract GapDepositNest {
    SwapPool immutable pool;
    address immutable token;
    uint256 nestedAmount;
    bool armed;

    constructor(address p, address t) {
        pool = SwapPool(p);
        token = t;
    }

    function approvePool() external {
        GapERC20(token).approve(address(pool), type(uint256).max);
    }

    function attack(uint256 outer, uint256 inner) external {
        nestedAmount = inner;
        armed = true;
        pool.deposit(token, outer);
    }

    function deposit(uint256 v) external {
        pool.deposit(token, v);
    }

    function onSend() external {
        if (!armed) return;
        armed = false;
        pool.deposit(token, nestedAmount);
    }
}

contract GapRegistry {
    mapping(address => bool) private allowed;

    function add(address t) external {
        allowed[t] = true;
    }

    function have(address t) external view returns (bool) {
        return allowed[t];
    }
}

contract GapLimiter is ILimiter {
    mapping(address => mapping(address => uint256)) private limits;

    function setLimit(address t, address h, uint256 v) external {
        limits[t][h] = v;
    }

    function limitOf(address t, address h) external view returns (uint256) {
        return limits[t][h];
    }
}

contract GapFeePolicy is IFeePolicy {
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
