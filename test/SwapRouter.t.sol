// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/SwapPool.sol";
import "../src/SwapRouter.sol";
import "../src/interfaces/IERC20.sol";
import "../src/interfaces/IFeePolicy.sol";
import "../src/interfaces/IQuoter.sol";
import "../src/interfaces/IProtocolFeeController.sol";
import "../src/interfaces/ILimiter.sol";

contract SwapRouterTest is Test {
    using LibClone for address;

    SwapRouter router;
    SwapPool implementation;

    MockERC20R tokenUSDT;
    MockERC20R tokenHAVANA;
    MockERC20R tokenTUKTUK;

    SwapPool poolA; // USDT <-> HAVANA
    SwapPool poolB; // HAVANA <-> TUKTUK

    MockFeePolicyR feePolicyA;
    MockFeePolicyR feePolicyB;
    MockQuoterR quoterA;
    MockQuoterR quoterB;
    MockTokenRegistryR registryA;
    MockTokenRegistryR registryB;
    MockLimiterR limiterA;
    MockLimiterR limiterB;
    MockProtocolFeeControllerR protocolCtrlA;
    MockProtocolFeeControllerR protocolCtrlB;

    address owner = makeAddr("owner");
    address feeAddr = makeAddr("feeAddr");

    function setUp() public {
        tokenUSDT = new MockERC20R("USDT", "USDT", 6);
        tokenHAVANA = new MockERC20R("HAVANA", "HAV", 18);
        tokenTUKTUK = new MockERC20R("TUKTUK", "TUK", 18);

        feePolicyA = new MockFeePolicyR();
        quoterA = new MockQuoterR();
        registryA = new MockTokenRegistryR();
        limiterA = new MockLimiterR();
        protocolCtrlA = new MockProtocolFeeControllerR();

        feePolicyB = new MockFeePolicyR();
        quoterB = new MockQuoterR();
        registryB = new MockTokenRegistryR();
        limiterB = new MockLimiterR();
        protocolCtrlB = new MockProtocolFeeControllerR();

        implementation = new SwapPool();

        address poolAAddr = LibClone.clone(address(implementation));
        poolA = SwapPool(poolAAddr);
        poolA.initialize(
            "Pool A",
            "PA",
            18,
            owner,
            address(feePolicyA),
            feeAddr,
            address(registryA),
            address(limiterA),
            address(quoterA),
            false,
            address(protocolCtrlA)
        );

        address poolBAddr = LibClone.clone(address(implementation));
        poolB = SwapPool(poolBAddr);
        poolB.initialize(
            "Pool B",
            "PB",
            18,
            owner,
            address(feePolicyB),
            feeAddr,
            address(registryB),
            address(limiterB),
            address(quoterB),
            false,
            address(protocolCtrlB)
        );

        registryA.addToken(address(tokenUSDT));
        registryA.addToken(address(tokenHAVANA));
        registryB.addToken(address(tokenHAVANA));
        registryB.addToken(address(tokenTUKTUK));

        limiterA.setLimit(address(tokenUSDT), address(poolA), type(uint256).max);
        limiterA.setLimit(address(tokenHAVANA), address(poolA), type(uint256).max);
        limiterB.setLimit(address(tokenHAVANA), address(poolB), type(uint256).max);
        limiterB.setLimit(address(tokenTUKTUK), address(poolB), type(uint256).max);

        tokenUSDT.mint(address(poolA), 100_000e6);
        tokenHAVANA.mint(address(poolA), 100_000e18);
        tokenHAVANA.mint(address(poolB), 100_000e18);
        tokenTUKTUK.mint(address(poolB), 100_000e18);

        router = new SwapRouter();

        // 1% fee on both pools, 1:1 quote
        feePolicyA.setFee(address(tokenUSDT), address(tokenHAVANA), 10_000);
        feePolicyA.setFee(address(tokenHAVANA), address(tokenUSDT), 10_000);
        feePolicyB.setFee(address(tokenHAVANA), address(tokenTUKTUK), 10_000);
        feePolicyB.setFee(address(tokenTUKTUK), address(tokenHAVANA), 10_000);
    }

    // --- Single-hop quotes ---

    function test_singleHop_quoteExactInput() public {
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](1);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));

        uint256 amountOut = router.quoteExactInput(path, 100e6);
        assertEq(amountOut, 99e6);
    }

    function test_singleHop_quoteExactOutput() public {
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](1);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));

        uint256 amountIn = router.quoteExactOutput(path, 99e6);
        assertEq(amountIn, 100e6 + 1); // +1 wei rounding
    }

    function test_singleHop_roundtrip() public {
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](1);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));

        uint256 desiredOut = 99e6;
        uint256 amountIn = router.quoteExactOutput(path, desiredOut);
        uint256 actualOut = router.quoteExactInput(path, amountIn);
        assertGe(actualOut, desiredOut, "roundtrip: output >= desired");
    }

    function test_singleHop_roundtrip_fuzz(uint256 desiredOut) public {
        desiredOut = bound(desiredOut, 1, 1000e6);

        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](1);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));

        uint256 amountIn = router.quoteExactOutput(path, desiredOut);
        uint256 actualOut = router.quoteExactInput(path, amountIn);
        assertGe(actualOut, desiredOut, "single-hop roundtrip fuzz");
    }

    // --- Multi-hop quotes ---

    function test_multiHop_quoteExactInput() public {
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](2);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));
        path[1] = SwapRouter.Hop(address(poolB), address(tokenHAVANA), address(tokenTUKTUK));

        uint256 amountOut = router.quoteExactInput(path, 100e6);

        // Hop 1: 100e6 → 99e6 (1% fee)
        // Hop 2: 99e6 → 98010000 (1% fee on 99e6)
        uint256 hop1Out = 99e6;
        uint256 expectedOut = hop1Out - (hop1Out * 10_000 / 1_000_000);
        assertEq(amountOut, expectedOut);
    }

    function test_multiHop_quoteExactOutput() public {
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](2);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));
        path[1] = SwapRouter.Hop(address(poolB), address(tokenHAVANA), address(tokenTUKTUK));

        uint256 desiredOut = 98010000;
        uint256 amountIn = router.quoteExactOutput(path, desiredOut);

        // Roundtrip verification
        uint256 actualOut = router.quoteExactInput(path, amountIn);
        assertGe(actualOut, desiredOut, "multi-hop roundtrip");
    }

    function test_multiHop_quoteExactOutput_with_protocol_fee() public {
        address protocolRecipient = makeAddr("protocolRecipient");
        protocolCtrlA.setProtocolFee(100_000); // 10%
        protocolCtrlA.setProtocolRecipient(protocolRecipient);
        protocolCtrlB.setProtocolFee(100_000);
        protocolCtrlB.setProtocolRecipient(protocolRecipient);

        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](2);
        path[0] = SwapRouter.Hop(address(poolA), address(tokenUSDT), address(tokenHAVANA));
        path[1] = SwapRouter.Hop(address(poolB), address(tokenHAVANA), address(tokenTUKTUK));

        uint256 desiredOut = 50e6;
        uint256 amountIn = router.quoteExactOutput(path, desiredOut);

        // Roundtrip verification with protocol fees active
        uint256 actualOut = router.quoteExactInput(path, amountIn);
        assertGe(actualOut, desiredOut, "multi-hop roundtrip with protocol fee");
    }

    // --- Edge cases ---

    function test_revert_emptyPath() public {
        SwapRouter.Hop[] memory path = new SwapRouter.Hop[](0);

        vm.expectRevert(SwapRouter.EmptyPath.selector);
        router.quoteExactInput(path, 100);

        vm.expectRevert(SwapRouter.EmptyPath.selector);
        router.quoteExactOutput(path, 100);
    }
}

// Mock contracts

contract MockERC20R is IERC20 {
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

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
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

contract MockFeePolicyR is IFeePolicy {
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

contract MockQuoterR is IQuoter {
    mapping(address => mapping(address => uint256)) private rates;

    function setRate(address outToken, address inToken, uint256 rate) external {
        rates[outToken][inToken] = rate;
    }

    function valueFor(address outToken, address inToken, uint256 value) external view returns (uint256) {
        uint256 rate = rates[outToken][inToken];
        if (rate == 0) return value;
        return value * rate;
    }

    function reverseValueFor(address outToken, address inToken, uint256 value) external view returns (uint256) {
        uint256 rate = rates[outToken][inToken];
        if (rate == 0) return value;
        return (value + rate - 1) / rate;
    }
}

contract MockTokenRegistryR {
    mapping(address => bool) private tokens;

    function addToken(address token) external {
        tokens[token] = true;
    }

    function have(address token) external view returns (bool) {
        return tokens[token];
    }
}

contract MockLimiterR is ILimiter {
    mapping(address => mapping(address => uint256)) private limits;

    function setLimit(address token, address holder, uint256 limit) external {
        limits[token][holder] = limit;
    }

    function limitOf(address token, address holder) external view returns (uint256) {
        return limits[token][holder];
    }
}

contract MockProtocolFeeControllerR is IProtocolFeeController {
    uint256 private protocolFee;
    address private protocolRecipient;

    function setProtocolFee(uint256 fee) external {
        protocolFee = fee;
    }

    function setProtocolRecipient(address r) external {
        protocolRecipient = r;
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
