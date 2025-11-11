// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/SwapPool.sol";
import "../src/interfaces/IERC20.sol";
import "../src/interfaces/IFeePolicy.sol";
import "../src/interfaces/IQuoter.sol";
import "../src/interfaces/IProtocolFeeController.sol";
import "../src/interfaces/ILimiter.sol";

contract SwapPoolTest is Test {
    using LibClone for address;

    error Sealed();
    error InvalidState();
    error AlreadyLocked();
    error TransferFailed();
    error InsufficientBalance();
    error UnauthorizedToken();
    error RegistryCallFailed();
    error LimitExceeded();
    error InvalidFeeAddress();
    error InsufficientFees();
    error InvalidInitialization();

    SwapPool pool;
    SwapPool implementation;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockFeePolicy feePolicy;
    MockQuoter quoter;
    MockTokenRegistry tokenRegistry;
    MockLimiter limiter;
    MockProtocolFeeController protocolFeeController;

    address owner = makeAddr("owner");
    address feeAddress = makeAddr("feeAddress");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    event SealStateChange(bool indexed _final, uint256 _sealState);
    event Swap(
        address indexed initiator,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event Deposit(address indexed initiator, address indexed tokenIn, uint256 amountIn);
    event Collect(address indexed feeAddress, address tokenOut, uint256 amountOut);

    function setUp() public {
        // Deploy mock contracts
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        feePolicy = new MockFeePolicy();
        quoter = new MockQuoter();
        tokenRegistry = new MockTokenRegistry();
        limiter = new MockLimiter();
        protocolFeeController = new MockProtocolFeeController();

        // Deploy swap pool
        implementation = new SwapPool();
        address poolAddress = LibClone.clone(address(implementation));
        pool = SwapPool(poolAddress);

        pool.initialize(
            "Swap Pool",
            "SWAP",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(tokenRegistry),
            address(limiter),
            address(quoter),
            false, // feesDecoupled
            address(protocolFeeController)
        );

        // Setup token allowances
        tokenRegistry.addToken(address(tokenA));
        tokenRegistry.addToken(address(tokenB));

        // Set high limits to allow operations
        limiter.setLimit(address(tokenA), address(pool), type(uint256).max);
        limiter.setLimit(address(tokenB), address(pool), type(uint256).max);

        // Mint tokens to users
        tokenA.mint(user1, 10000e18);
        tokenB.mint(user1, 10000e18);
        tokenA.mint(user2, 10000e18);
        tokenB.mint(user2, 10000e18);

        // Add liquidity to pool
        tokenA.mint(address(pool), 50000e18);
        tokenB.mint(address(pool), 50000e18);
    }

    function test_initialize() public view {
        assertEq(pool.name(), "Swap Pool");
        assertEq(pool.symbol(), "SWAP");
        assertEq(pool.decimals(), 18);
        assertEq(pool.owner(), owner);
        assertEq(pool.feePolicy(), address(feePolicy));
        assertEq(pool.feeAddress(), feeAddress);
        assertEq(pool.tokenRegistry(), address(tokenRegistry));
        assertEq(pool.tokenLimiter(), address(limiter));
        assertEq(pool.quoter(), address(quoter));
        assertFalse(pool.feesDecoupled());
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        pool.initialize(
            "Should Fail",
            "FAIL",
            18,
            owner,
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            false,
            address(0)
        );
    }

    function test_deposit_success() public {
        uint256 amount = 1000e18;

        vm.startPrank(user1);
        tokenA.approve(address(pool), amount);

        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, address(tokenA), amount);

        pool.deposit(address(tokenA), amount);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(address(pool)), 50000e18 + amount);
    }

    function test_deposit_revertIf_unauthorized_token() public {
        MockERC20 unauthorizedToken = new MockERC20("Unauthorized", "UNAUTH", 18);
        unauthorizedToken.mint(user1, 1000e18);

        uint256 amount = 1000e18;

        vm.startPrank(user1);
        unauthorizedToken.approve(address(pool), amount);

        vm.expectRevert(UnauthorizedToken.selector);
        pool.deposit(address(unauthorizedToken), amount);
        vm.stopPrank();
    }

    function test_deposit_revertIf_limit_exceeded() public {
        limiter.setLimit(address(tokenA), address(pool), 51000e18);

        uint256 amount = 2000e18;

        vm.startPrank(user1);
        tokenA.approve(address(pool), amount);

        vm.expectRevert(LimitExceeded.selector);
        pool.deposit(address(tokenA), amount);
        vm.stopPrank();
    }

    function test_swap_without_fees() public {
        // Set fee to 0
        feePolicy.setFee(address(tokenA), address(tokenB), 0);

        uint256 amountIn = 100e18;

        vm.startPrank(user1);
        tokenA.approve(address(pool), amountIn);

        uint256 balanceBefore = tokenB.balanceOf(user1);

        vm.expectEmit(true, true, false, true);
        emit Swap(user1, address(tokenA), address(tokenB), amountIn, amountIn, 0);

        pool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();

        assertEq(tokenB.balanceOf(user1), balanceBefore + amountIn);
        assertEq(pool.fees(address(tokenB)), 0);
    }

    function test_swap_with_fees() public {
        // Set fee to 1% (10000 PPM)
        feePolicy.setFee(address(tokenA), address(tokenB), 10000);

        uint256 amountIn = 100e18;
        uint256 expectedFee = (amountIn * 10000) / 1_000_000; // 1e18
        uint256 expectedOut = amountIn - expectedFee; // 99e18

        vm.startPrank(user1);
        tokenA.approve(address(pool), amountIn);

        uint256 balanceBefore = tokenB.balanceOf(user1);

        vm.expectEmit(true, true, false, true);
        emit Swap(user1, address(tokenA), address(tokenB), amountIn, amountIn, expectedFee);

        pool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();

        assertEq(tokenB.balanceOf(user1), balanceBefore + expectedOut);
        assertEq(pool.fees(address(tokenB)), expectedFee);
    }

    function test_swap_with_quoter() public {
        // Set quoter to return 2x the input (2:1 ratio)
        quoter.setRate(address(tokenB), address(tokenA), 2);
        feePolicy.setFee(address(tokenA), address(tokenB), 0);

        uint256 amountIn = 100e18;
        uint256 expectedOut = 200e18; // 2x due to quoter

        vm.startPrank(user1);
        tokenA.approve(address(pool), amountIn);

        uint256 balanceBefore = tokenB.balanceOf(user1);

        pool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();

        assertEq(tokenB.balanceOf(user1), balanceBefore + expectedOut);
    }

    function test_swap_revertIf_insufficient_balance() public {
        feePolicy.setFee(address(tokenA), address(tokenB), 0);

        // Try to swap more than pool has
        uint256 amountIn = 60000e18;

        vm.startPrank(user1);
        tokenA.mint(user1, amountIn);
        tokenA.approve(address(pool), amountIn);

        vm.expectRevert(InsufficientBalance.selector);
        pool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();
    }

    function test_swap_with_decoupled_fees() public {
        // Deploy new pool with decoupled fees
        address poolAddress = LibClone.clone(address(implementation));
        SwapPool decoupledPool = SwapPool(poolAddress);

        decoupledPool.initialize(
            "Decoupled Pool",
            "DSWAP",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(tokenRegistry),
            address(limiter),
            address(quoter),
            true, // feesDecoupled
            address(protocolFeeController)
        );

        // Set limits for the decoupled pool
        limiter.setLimit(address(tokenA), address(decoupledPool), type(uint256).max);
        limiter.setLimit(address(tokenB), address(decoupledPool), type(uint256).max);

        // Add liquidity
        tokenA.mint(address(decoupledPool), 1000e18);
        tokenB.mint(address(decoupledPool), 1000e18);

        // Set fee to 1%
        feePolicy.setFee(address(tokenA), address(tokenB), 10000);

        // First swap accumulates fees
        uint256 amountIn = 100e18;
        vm.startPrank(user1);
        tokenA.approve(address(decoupledPool), amountIn);
        decoupledPool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();

        uint256 accumulatedFees = decoupledPool.fees(address(tokenB));
        assertEq(accumulatedFees, 1e18); // 1% of 100

        // Now try to swap more than available liquidity (excluding fees)
        // Pool has 1000 - 99 = 901 tokenB left
        // But 1 is locked in fees, so available = 900
        uint256 amountIn2 = 901e18;
        vm.startPrank(user2);
        tokenA.approve(address(decoupledPool), amountIn2);

        vm.expectRevert(InsufficientBalance.selector);
        decoupledPool.withdraw(address(tokenB), address(tokenA), amountIn2);
        vm.stopPrank();
    }

    function test_collectFees() public {
        // Accumulate some fees first
        feePolicy.setFee(address(tokenA), address(tokenB), 10000); // 1%

        uint256 amountIn = 100e18;
        vm.startPrank(user1);
        tokenA.approve(address(pool), amountIn);
        pool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();

        uint256 accumulatedFees = pool.fees(address(tokenB));
        assertEq(accumulatedFees, 1e18);

        // Collect fees
        uint256 feeBalanceBefore = tokenB.balanceOf(feeAddress);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Collect(feeAddress, address(tokenB), accumulatedFees);

        uint256 collected = pool.withdraw(address(tokenB), accumulatedFees);

        assertEq(collected, accumulatedFees);
        assertEq(tokenB.balanceOf(feeAddress), feeBalanceBefore + accumulatedFees);
        assertEq(pool.fees(address(tokenB)), 0);
    }

    function test_collectFees_all() public {
        // Accumulate some fees first
        feePolicy.setFee(address(tokenA), address(tokenB), 10000); // 1%

        uint256 amountIn = 100e18;
        vm.startPrank(user1);
        tokenA.approve(address(pool), amountIn);
        pool.withdraw(address(tokenB), address(tokenA), amountIn);
        vm.stopPrank();

        uint256 accumulatedFees = pool.fees(address(tokenB));

        // Collect all fees using withdraw(token) overload
        vm.prank(owner);
        uint256 collected = pool.withdraw(address(tokenB));

        assertEq(collected, accumulatedFees);
        assertEq(pool.fees(address(tokenB)), 0);
    }

    function test_collectFees_revertIf_invalid_fee_address() public {
        // Deploy pool without fee address
        address poolAddress = LibClone.clone(address(implementation));
        SwapPool newPool = SwapPool(poolAddress);

        newPool.initialize(
            "No Fee Pool",
            "NFEE",
            18,
            owner,
            address(feePolicy),
            address(0), // No fee address
            address(tokenRegistry),
            address(limiter),
            address(quoter),
            false,
            address(protocolFeeController)
        );

        vm.prank(owner);
        vm.expectRevert(InvalidFeeAddress.selector);
        newPool.withdraw(address(tokenB), 1e18);
    }

    function test_collectFees_revertIf_insufficient_fees() public {
        vm.prank(owner);
        vm.expectRevert(InsufficientFees.selector);
        pool.withdraw(address(tokenB), 1e18);
    }

    function test_collectFees_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.withdraw(address(tokenB), 1e18);
    }

    function test_withdrawLiquidity() public {
        uint256 amount = 1000e18;
        uint256 balanceBefore = tokenA.balanceOf(user1);

        vm.prank(owner);
        uint256 withdrawn = pool.withdrawLiquidity(address(tokenA), user1, amount);

        assertEq(withdrawn, amount);
        assertEq(tokenA.balanceOf(user1), balanceBefore + amount);
    }

    function test_withdrawLiquidity_revertIf_insufficient_balance() public {
        uint256 amount = 100000e18; // More than pool has

        vm.prank(owner);
        vm.expectRevert(InsufficientBalance.selector);
        pool.withdrawLiquidity(address(tokenA), user1, amount);
    }

    function test_withdrawLiquidity_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.withdrawLiquidity(address(tokenA), user1, 1000e18);
    }

    function test_getAmountOut() public {
        feePolicy.setFee(address(tokenA), address(tokenB), 10000); // 1%

        uint256 amountIn = 100e18;
        uint256 expectedOut = 99e18; // 100 - 1% fee

        uint256 amountOut = pool.getAmountOut(address(tokenB), address(tokenA), amountIn);

        assertEq(amountOut, expectedOut);
    }

    function test_getAmountOut_with_quoter() public {
        quoter.setRate(address(tokenB), address(tokenA), 2);
        feePolicy.setFee(address(tokenA), address(tokenB), 10000); // 1%

        uint256 amountIn = 100e18;
        uint256 quotedValue = 200e18; // 2x due to quoter
        uint256 expectedFee = (quotedValue * 10000) / 1_000_000; // 2e18
        uint256 expectedOut = quotedValue - expectedFee; // 198e18

        uint256 amountOut = pool.getAmountOut(address(tokenB), address(tokenA), amountIn);

        assertEq(amountOut, expectedOut);
    }

    function test_getAmountIn() public {
        feePolicy.setFee(address(tokenA), address(tokenB), 10000); // 1%

        uint256 desiredOut = 99e18;
        // To get 99 out, we need: amountIn = 99 * 1_000_000 / (1_000_000 - 10000) = 99 * 1_000_000 / 990000 = 100
        uint256 expectedIn = 100e18;

        uint256 amountIn = pool.getAmountIn(address(tokenB), address(tokenA), desiredOut);

        assertEq(amountIn, expectedIn);
    }

    function test_getAmountIn_no_fees() public {
        feePolicy.setFee(address(tokenA), address(tokenB), 0);

        uint256 desiredOut = 100e18;
        uint256 amountIn = pool.getAmountIn(address(tokenB), address(tokenA), desiredOut);

        assertEq(amountIn, desiredOut);
    }

    function test_seal_feePolicy() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SealStateChange(false, 1);

        uint8 state = pool.seal(1);

        assertEq(state, 1);
        assertTrue(pool.isSealed(1));
    }

    function test_seal_multiple_states() public {
        vm.startPrank(owner);

        pool.seal(1); // Seal fee policy
        pool.seal(2); // Seal fee address

        assertEq(pool.sealState(), 3);
        assertTrue(pool.isSealed(1));
        assertTrue(pool.isSealed(2));
        assertFalse(pool.isSealed(0)); // Not fully sealed

        vm.stopPrank();
    }

    function test_seal_all() public {
        vm.startPrank(owner);

        pool.seal(1);
        pool.seal(2);

        vm.expectEmit(true, false, false, true);
        emit SealStateChange(true, 7);

        pool.seal(4);

        assertTrue(pool.isSealed(0)); // Fully sealed
        assertEq(pool.sealState(), 7);

        vm.stopPrank();
    }

    function test_seal_revertIf_already_sealed() public {
        vm.startPrank(owner);

        pool.seal(1);

        vm.expectRevert(AlreadyLocked.selector);
        pool.seal(1);

        vm.stopPrank();
    }

    function test_seal_revertIf_invalid_state() public {
        vm.prank(owner);
        vm.expectRevert(InvalidState.selector);
        pool.seal(8);
    }

    function test_seal_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.seal(1);
    }

    function test_setFeePolicy_revertIf_sealed() public {
        vm.startPrank(owner);
        pool.seal(1);

        vm.expectRevert(Sealed.selector);
        pool.setFeePolicy(address(0));

        vm.stopPrank();
    }

    function test_setFeeAddress_revertIf_sealed() public {
        vm.startPrank(owner);
        pool.seal(2);

        vm.expectRevert(Sealed.selector);
        pool.setFeeAddress(address(0));

        vm.stopPrank();
    }

    function test_setQuoter_revertIf_sealed() public {
        vm.startPrank(owner);
        pool.seal(4);

        vm.expectRevert(Sealed.selector);
        pool.setQuoter(address(0));

        vm.stopPrank();
    }

    function test_setFeePolicy() public {
        address newFeePolicy = makeAddr("newFeePolicy");

        vm.prank(owner);
        pool.setFeePolicy(newFeePolicy);

        assertEq(pool.feePolicy(), newFeePolicy);
    }

    function test_setFeeAddress() public {
        address newFeeAddress = makeAddr("newFeeAddress");

        vm.prank(owner);
        pool.setFeeAddress(newFeeAddress);

        assertEq(pool.feeAddress(), newFeeAddress);
    }

    function test_setQuoter() public {
        address newQuoter = makeAddr("newQuoter");

        vm.prank(owner);
        pool.setQuoter(newQuoter);

        assertEq(pool.quoter(), newQuoter);
    }

    function test_setTokenRegistry() public {
        address newRegistry = makeAddr("newRegistry");

        vm.prank(owner);
        pool.setTokenRegistry(newRegistry);

        assertEq(pool.tokenRegistry(), newRegistry);
    }

    function test_setTokenLimiter() public {
        address newLimiter = makeAddr("newLimiter");

        vm.prank(owner);
        pool.setTokenLimiter(newLimiter);

        assertEq(pool.tokenLimiter(), newLimiter);
    }

    function test_setters_revertIf_not_owner() public {
        vm.startPrank(user1);

        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setFeePolicy(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setFeeAddress(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setQuoter(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setTokenRegistry(address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setTokenLimiter(address(0));

        vm.stopPrank();
    }

    function test_getFee() public {
        feePolicy.setFee(address(tokenA), address(tokenB), 50000); // 5%

        uint256 value = 100e18;
        uint256 fee = pool.getFee(address(tokenA), address(tokenB), value);

        assertEq(fee, 5e18); // 5% of 100
    }

    function test_getFee_no_policy() public {
        // Deploy pool without fee policy
        address poolAddress = LibClone.clone(address(implementation));
        SwapPool newPool = SwapPool(poolAddress);

        newPool.initialize(
            "No Fee Pool",
            "NFEE",
            18,
            owner,
            address(0), // No fee policy
            feeAddress,
            address(tokenRegistry),
            address(limiter),
            address(quoter),
            false,
            address(protocolFeeController)
        );

        uint256 fee = newPool.getFee(address(tokenA), address(tokenB), 100e18);

        assertEq(fee, 0);
    }

    function test_getQuote() public {
        quoter.setRate(address(tokenB), address(tokenA), 3);

        uint256 value = 100e18;
        uint256 quote = pool.getQuote(address(tokenB), address(tokenA), value);

        assertEq(quote, 300e18); // 3x rate
    }

    function test_getQuote_no_quoter() public {
        // Deploy pool without quoter
        address poolAddress = LibClone.clone(address(implementation));
        SwapPool newPool = SwapPool(poolAddress);

        newPool.initialize(
            "No Quoter Pool",
            "NQUOTE",
            18,
            owner,
            address(feePolicy),
            feeAddress,
            address(tokenRegistry),
            address(limiter),
            address(0), // No quoter
            false,
            address(protocolFeeController)
        );

        uint256 value = 100e18;
        uint256 quote = newPool.getQuote(address(tokenB), address(tokenA), value);

        assertEq(quote, value); // 1:1 when no quoter
    }
}

// Mock Contracts

contract MockERC20 is IERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }
}

contract MockFeePolicy is IFeePolicy {
    mapping(address => mapping(address => uint256)) private fees;

    function setFee(address tokenIn, address tokenOut, uint256 fee) external {
        fees[tokenIn][tokenOut] = fee;
    }

    function getFee(address tokenIn, address tokenOut) external view returns (uint256) {
        return fees[tokenIn][tokenOut];
    }

    function isActive() external pure returns (bool) {
        return true;
    }
}

contract MockQuoter is IQuoter {
    mapping(address => mapping(address => uint256)) private rates;

    function setRate(address outToken, address inToken, uint256 rate) external {
        rates[outToken][inToken] = rate;
    }

    function valueFor(address outToken, address inToken, uint256 value) external view returns (uint256) {
        uint256 rate = rates[outToken][inToken];
        if (rate == 0) {
            return value;
        }
        return value * rate;
    }
}

contract MockTokenRegistry {
    mapping(address => bool) private tokens;

    function addToken(address token) external {
        tokens[token] = true;
    }

    function removeToken(address token) external {
        tokens[token] = false;
    }

    function have(address token) external view returns (bool) {
        return tokens[token];
    }
}

contract MockLimiter is ILimiter {
    mapping(address => mapping(address => uint256)) private limits;

    function setLimit(address token, address holder, uint256 limit) external {
        limits[token][holder] = limit;
    }

    function limitOf(address token, address holder) external view returns (uint256) {
        return limits[token][holder];
    }
}

contract MockProtocolFeeController is IProtocolFeeController {
    uint256 private protocolFee;
    address private protocolRecipient;

    function setProtocolFee(uint256 fee) external {
        protocolFee = fee;
    }

    function setProtocolRecipient(address recipient) external {
        protocolRecipient = recipient;
    }

    function getProtocolFee() external view returns (uint256) {
        return protocolFee;
    }

    function getProtocolFeeRecipient() external view returns (address) {
        return protocolRecipient;
    }

    function isActive() external pure returns (bool) {
        return true;
    }
}
