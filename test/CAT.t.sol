// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/CAT.sol";

contract CATTest is Test {
    using LibClone for address;

    error TooManyTokens();
    error EmptyTokenList();
    error ZeroAddress();
    error InvalidInitialization();

    CAT cat;
    CAT implementation;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address writer = makeAddr("writer");
    address token1 = makeAddr("token1");
    address token2 = makeAddr("token2");
    address token3 = makeAddr("token3");

    event TokensSet(address indexed account, address[] tokens);
    event WriterAdded(address indexed writer);
    event WriterRemoved(address indexed writer);

    function setUp() public {
        implementation = new CAT();
        address catAddress = LibClone.clone(address(implementation));
        cat = CAT(catAddress);
        cat.initialize(owner);

        vm.startPrank(owner);
        cat.addWriter(writer);
        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(cat.owner(), owner);
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        cat.initialize(user1);
    }

    function test_setTokens_and_getTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        vm.prank(user1);
        cat.setTokens(tokens);

        address[] memory result = cat.getTokens(user1);
        assertEq(result.length, 2);
        assertEq(result[0], token1);
        assertEq(result[1], token2);
    }

    function test_tokenAt() public {
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        vm.prank(user1);
        cat.setTokens(tokens);

        assertEq(cat.tokenAt(user1, 0), token1);
        assertEq(cat.tokenAt(user1, 1), token2);
    }

    function test_tokenCount() public {
        address[] memory tokens = new address[](3);
        tokens[0] = token1;
        tokens[1] = token2;
        tokens[2] = token3;

        vm.prank(user1);
        cat.setTokens(tokens);

        assertEq(cat.tokenCount(user1), 3);
    }

    function test_setTokens_replaces_previous() public {
        address[] memory tokens1 = new address[](2);
        tokens1[0] = token1;
        tokens1[1] = token2;

        vm.prank(user1);
        cat.setTokens(tokens1);

        address[] memory tokens2 = new address[](1);
        tokens2[0] = token3;

        vm.prank(user1);
        cat.setTokens(tokens2);

        address[] memory result = cat.getTokens(user1);
        assertEq(result.length, 1);
        assertEq(result[0], token3);
    }

    function test_setTokens_revertIf_too_many() public {
        address[] memory tokens = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            tokens[i] = makeAddr(string(abi.encodePacked("tok", i)));
        }

        vm.prank(user1);
        vm.expectRevert(TooManyTokens.selector);
        cat.setTokens(tokens);
    }

    function test_setTokens_revertIf_empty() public {
        address[] memory tokens = new address[](0);

        vm.prank(user1);
        vm.expectRevert(EmptyTokenList.selector);
        cat.setTokens(tokens);
    }

    function test_setTokens_revertIf_zero_address() public {
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = address(0);

        vm.prank(user1);
        vm.expectRevert(ZeroAddress.selector);
        cat.setTokens(tokens);
    }

    function test_multiple_accounts_independent() public {
        address[] memory tokens1 = new address[](1);
        tokens1[0] = token1;

        address[] memory tokens2 = new address[](1);
        tokens2[0] = token2;

        vm.prank(user1);
        cat.setTokens(tokens1);

        vm.prank(user2);
        cat.setTokens(tokens2);

        assertEq(cat.getTokens(user1)[0], token1);
        assertEq(cat.getTokens(user2)[0], token2);
    }

    function test_setTokensFor_by_writer() public {
        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        vm.prank(writer);
        cat.setTokensFor(user1, tokens);

        address[] memory result = cat.getTokens(user1);
        assertEq(result.length, 2);
        assertEq(result[0], token1);
        assertEq(result[1], token2);
    }

    function test_setTokensFor_by_owner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        vm.prank(owner);
        cat.setTokensFor(user1, tokens);

        assertEq(cat.getTokens(user1)[0], token1);
    }

    function test_setTokensFor_revertIf_unauthorized() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        vm.prank(user1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        cat.setTokensFor(user2, tokens);
    }

    function test_addWriter() public {
        address newWriter = makeAddr("newWriter");

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WriterAdded(newWriter);
        cat.addWriter(newWriter);

        assertTrue(cat.isWriter(newWriter));
    }

    function test_deleteWriter() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit WriterRemoved(writer);
        cat.deleteWriter(writer);

        assertFalse(cat.isWriter(writer));
    }

    function test_isWriter_owner_is_always_writer() public view {
        assertTrue(cat.isWriter(owner));
    }

    function test_emits_TokensSet() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit TokensSet(user1, tokens);
        cat.setTokens(tokens);
    }
}
