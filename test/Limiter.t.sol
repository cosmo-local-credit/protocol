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
    address writer = makeAddr("writer");
    address token1 = makeAddr("token1");
    address token2 = makeAddr("token2");

    address mockContract;

    event LimitSet(
        address indexed token,
        address indexed holder,
        uint256 value
    );
    event WriterAdded(address indexed writer);
    event WriterRemoved(address indexed writer);

    function setUp() public {
        implementation = new Limiter();
        address limiterAddress = LibClone.clone(address(implementation));
        limiter = Limiter(limiterAddress);
        limiter.initialize(owner);

        mockContract = address(new MockContract());

        vm.startPrank(owner);
        limiter.addWriter(writer);
        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(limiter.owner(), owner);
    }

    function test_addWriter() public {
        address newWriter = makeAddr("newWriter");

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WriterAdded(newWriter);
        limiter.addWriter(newWriter);

        assertTrue(limiter.isWriter(newWriter));
    }

    function test_deleteWriter() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WriterRemoved(writer);
        limiter.deleteWriter(writer);

        assertFalse(limiter.isWriter(writer));
    }

    function test_isWriter_owner_is_always_writer() public view {
        assertTrue(limiter.isWriter(owner));
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        limiter.initialize(user1);
    }

    function test_setLimitFor_by_owner() public {
        uint256 limitValue = 5000e18;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit LimitSet(token1, mockContract, limitValue);
        limiter.setLimitFor(token1, mockContract, limitValue);

        assertEq(limiter.limitOf(token1, mockContract), limitValue);
    }

    function test_setLimitFor_by_writer() public {
        uint256 limitValue = 3000e18;

        vm.prank(writer);
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

    function test_supportsInterface() public view {
        assertTrue(limiter.supportsInterface(0x01ffc9a7));
        assertTrue(limiter.supportsInterface(0x7f5828d0));
        assertTrue(limiter.supportsInterface(0x23778613));
        assertFalse(limiter.supportsInterface(0x12345678));
    }
}

contract MockContract {
    // Empty contract with code
}
