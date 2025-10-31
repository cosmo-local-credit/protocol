// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/GiftableToken.sol";

contract GiftableTokenTest is Test {
    using LibClone for address;

    error Unauthorized();
    error TokenExpired();
    error InsufficientBalance();
    error InvalidInitialization();

    GiftableToken token;
    GiftableToken implementation;

    address owner = makeAddr("owner");
    address minter = makeAddr("minter");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    event Mint(address indexed minter, address indexed beneficiary, uint256 value);
    event Burn(address indexed from, uint256 value);
    event Expired(uint256 timestamp);
    event WriterAdded(address indexed writer);
    event WriterRemoved(address indexed writer);

    function setUp() public {
        implementation = new GiftableToken();
        address tokenAddress = LibClone.clone(address(implementation));
        token = GiftableToken(tokenAddress);
        token.initialize("Test Voucher", "TST", 6, owner, 0);
        vm.prank(owner);
        token.addWriter(minter);
    }

    function test_getters() public view {
        assertEq(token.name(), "Test Voucher");
        assertEq(token.symbol(), "TST");
        assertEq(token.decimals(), 6);
        assertEq(token.owner(), owner);
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        token.initialize("Should Fail", "FAIL", 18, owner, 0);
    }

    function test_totalSupply() public {
        assertEq(token.totalSupply(), 0);
        vm.prank(minter);
        token.mintTo(user1, 1000);
        assertEq(token.totalSupply(), 1000);
        assertEq(token.totalMinted(), 1000);
        assertEq(token.totalBurned(), 0);
    }

    function test_totalSupply_afterBurn() public {
        vm.prank(minter);
        token.mintTo(owner, 1000);

        vm.prank(owner);
        token.burn(300);

        assertEq(token.totalSupply(), 700);
        assertEq(token.totalMinted(), 1000);
        assertEq(token.totalBurned(), 300);
        assertEq(token.totalMinted() - token.totalBurned(), token.totalSupply());
    }

    function test_addWriter() public {
        address newWriter = makeAddr("newWriter");
        vm.expectEmit(true, false, false, false);
        emit WriterAdded(newWriter);

        vm.prank(owner);
        bool success = token.addWriter(newWriter);

        assertTrue(success);
        assertTrue(token.writers(newWriter));
        assertTrue(token.isWriter(newWriter));
    }

    function test_addWriter_revertIf_not_owner() public {
        address newWriter = makeAddr("newWriter");

        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        token.addWriter(newWriter);
    }

    function test_deleteWriter() public {
        vm.expectEmit(true, false, false, false);
        emit WriterRemoved(minter);

        vm.prank(owner);
        bool success = token.deleteWriter(minter);

        assertTrue(success);
        assertFalse(token.writers(minter));
        assertFalse(token.isWriter(minter));
    }

    function test_deleteWriter_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        token.deleteWriter(minter);
    }

    function test_isWriter_returnsTrue_forOwner() public view {
        assertTrue(token.isWriter(owner));
    }

    function test_isWriter_returnsTrue_forWriter() public view {
        assertTrue(token.isWriter(minter));
    }

    function test_isWriter_returnsFalse_forNonWriter() public view {
        assertFalse(token.isWriter(user1));
    }

    function test_mintTo_byWriter() public {
        vm.expectEmit(true, true, false, true);
        emit Mint(minter, user1, 100);

        vm.prank(minter);
        token.mintTo(user1, 100);

        assertEq(token.balanceOf(user1), 100);
        assertEq(token.totalMinted(), 100);
        assertEq(token.totalSupply(), 100);
    }

    function test_mintTo_byOwner() public {
        vm.expectEmit(true, true, false, true);
        emit Mint(owner, user1, 200);

        vm.prank(owner);
        token.mintTo(user1, 200);

        assertEq(token.balanceOf(user1), 200);
        assertEq(token.totalMinted(), 200);
    }

    function test_mintTo_revertIf_not_writer() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        token.mintTo(user2, 100);
    }

    function test_mintTo_multiple() public {
        vm.startPrank(minter);
        token.mintTo(user1, 100);
        token.mintTo(user2, 200);
        token.mintTo(user1, 50);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 150);
        assertEq(token.balanceOf(user2), 200);
        assertEq(token.totalMinted(), 350);
        assertEq(token.totalSupply(), 350);
    }

    function test_burn() public {
        vm.prank(minter);
        token.mintTo(owner, 1000);

        vm.expectEmit(true, false, false, true);
        emit Burn(owner, 300);

        vm.prank(owner);
        token.burn(300);

        assertEq(token.balanceOf(owner), 700);
        assertEq(token.totalBurned(), 300);
        assertEq(token.totalSupply(), 700);
    }

    function test_burn_revertIf_insufficient_balance() public {
        vm.prank(minter);
        token.mintTo(owner, 100);

        vm.prank(owner);
        vm.expectRevert(InsufficientBalance.selector);
        token.burn(200);
    }

    function test_burn_revertIf_not_owner() public {
        vm.prank(minter);
        token.mintTo(user1, 1000);

        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        token.burn(100);
    }

    function test_applyExpiry_noExpiry() public {
        uint8 result = token.applyExpiry();
        assertEq(result, 0);
        assertFalse(token.expired());
    }

    function test_applyExpiry_notExpiredYet() public {
        uint256 expiryTime = block.timestamp + 1000;
        address tokenAddress = LibClone.clone(address(implementation));
        GiftableToken newToken = GiftableToken(tokenAddress);
        newToken.initialize("Expiring Token", "EXP", 6, owner, expiryTime);

        uint8 result = newToken.applyExpiry();
        assertEq(result, 0);
        assertFalse(newToken.expired());
    }

    function test_applyExpiry_expired() public {
        uint256 expiryTime = block.timestamp + 1000;
        address tokenAddress = LibClone.clone(address(implementation));
        GiftableToken newToken = GiftableToken(tokenAddress);
        newToken.initialize("Expiring Token", "EXP", 6, owner, expiryTime);

        vm.warp(expiryTime);

        vm.expectEmit(false, false, false, true);
        emit Expired(block.timestamp);

        uint8 result = newToken.applyExpiry();
        assertEq(result, 2);
        assertTrue(newToken.expired());
    }

    function test_applyExpiry_alreadyExpired() public {
        uint256 expiryTime = block.timestamp + 1000;
        address tokenAddress = LibClone.clone(address(implementation));
        GiftableToken newToken = GiftableToken(tokenAddress);
        newToken.initialize("Expiring Token", "EXP", 6, owner, expiryTime);

        vm.warp(expiryTime);
        newToken.applyExpiry();

        uint8 result = newToken.applyExpiry();
        assertEq(result, 1);
        assertTrue(newToken.expired());
    }

    function test_transfer_revertIf_expired() public {
        uint256 expiryTime = block.timestamp + 1000;
        address tokenAddress = LibClone.clone(address(implementation));
        GiftableToken newToken = GiftableToken(tokenAddress);
        newToken.initialize("Expiring Token", "EXP", 6, owner, expiryTime);

        vm.prank(owner);
        newToken.addWriter(minter);

        vm.prank(minter);
        newToken.mintTo(user1, 1000);

        vm.warp(expiryTime);

        vm.prank(user1);
        vm.expectRevert(TokenExpired.selector);
        newToken.transfer(user2, 100);
    }

    function test_transfer_success_notExpired() public {
        vm.prank(minter);
        token.mintTo(user1, 1000);

        vm.prank(user1);
        token.transfer(user2, 100);

        assertEq(token.balanceOf(user1), 900);
        assertEq(token.balanceOf(user2), 100);
    }

    function test_transferFrom_revertIf_expired() public {
        uint256 expiryTime = block.timestamp + 1000;
        address tokenAddress = LibClone.clone(address(implementation));
        GiftableToken newToken = GiftableToken(tokenAddress);
        newToken.initialize("Expiring Token", "EXP", 6, owner, expiryTime);

        vm.prank(owner);
        newToken.addWriter(minter);

        vm.prank(minter);
        newToken.mintTo(user1, 1000);

        vm.prank(user1);
        newToken.approve(user2, 500);

        vm.warp(expiryTime);

        vm.prank(user2);
        vm.expectRevert(TokenExpired.selector);
        newToken.transferFrom(user1, user2, 100);
    }
}
