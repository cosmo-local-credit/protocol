// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/Limiter.sol";

contract LimiterTest is Test {
    using LibClone for address;

    error InvalidHolder();
    error InvalidInitialization();

    Limiter limiter;
    Limiter implementation;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address token1 = makeAddr("token1");
    address token2 = makeAddr("token2");

    // Mock contract address for testing setLimitFor
    address mockContract;

    event LimitSet(
        address indexed token,
        address indexed holder,
        uint256 value
    );

    function setUp() public {
        implementation = new Limiter();
        address limiterAddress = LibClone.clone(address(implementation));
        limiter = Limiter(limiterAddress);
        limiter.initialize(owner);

        // Deploy a mock contract for setLimitFor tests
        mockContract = address(new MockContract());
    }

    function test_initialize() public view {
        assertEq(limiter.owner(), owner);
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        limiter.initialize(user1);
    }

    function test_setLimit() public {
        uint256 limitValue = 1000e18;

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit LimitSet(token1, user1, limitValue);
        limiter.setLimit(token1, limitValue);

        assertEq(limiter.limitOf(token1, user1), limitValue);
    }

    function test_setLimit_multiple_tokens() public {
        uint256 limit1 = 1000e18;
        uint256 limit2 = 2000e18;

        vm.startPrank(user1);
        limiter.setLimit(token1, limit1);
        limiter.setLimit(token2, limit2);
        vm.stopPrank();

        assertEq(limiter.limitOf(token1, user1), limit1);
        assertEq(limiter.limitOf(token2, user1), limit2);
    }

    function test_setLimit_update_existing() public {
        uint256 initialLimit = 1000e18;
        uint256 newLimit = 2000e18;

        vm.startPrank(user1);
        limiter.setLimit(token1, initialLimit);
        assertEq(limiter.limitOf(token1, user1), initialLimit);

        limiter.setLimit(token1, newLimit);
        assertEq(limiter.limitOf(token1, user1), newLimit);
        vm.stopPrank();
    }

    function test_setLimitFor_by_owner() public {
        uint256 limitValue = 5000e18;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit LimitSet(token1, mockContract, limitValue);
        limiter.setLimitFor(token1, mockContract, limitValue);

        assertEq(limiter.limitOf(token1, mockContract), limitValue);
    }

    function test_setLimitFor_by_holder() public {
        uint256 limitValue = 3000e18;

        vm.prank(mockContract);
        vm.expectEmit(true, true, false, true);
        emit LimitSet(token1, mockContract, limitValue);
        limiter.setLimitFor(token1, mockContract, limitValue);

        assertEq(limiter.limitOf(token1, mockContract), limitValue);
    }

    function test_setLimitFor_revertIf_unauthorized() public {
        uint256 limitValue = 3000e18;

        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        limiter.setLimitFor(token1, mockContract, limitValue);
    }

    function test_setLimitFor_revertIf_not_contract() public {
        uint256 limitValue = 3000e18;

        vm.prank(owner);
        vm.expectRevert(InvalidHolder.selector);
        limiter.setLimitFor(token1, user1, limitValue);
    }

    function test_limitOf_returns_zero_if_not_set() public view {
        assertEq(limiter.limitOf(token1, user1), 0);
    }

    function testFuzz_setLimit(address token, uint256 limit) public {
        vm.prank(user1);
        limiter.setLimit(token, limit);
        assertEq(limiter.limitOf(token, user1), limit);
    }
}

// Mock contract for testing setLimitFor
contract MockContract {
    // Empty contract with code
}
