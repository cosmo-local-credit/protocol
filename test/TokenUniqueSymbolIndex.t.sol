// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/TokenUniqueSymbolIndex.sol";

contract TokenUniqueSymbolIndexTest is Test {
    using LibClone for address;

    error Access();
    error TokenSymbolTooLong();
    error NotFound();
    error SymbolAlreadyExists();
    error Unauthorized();

    TokenUniqueSymbolIndex index;
    TokenUniqueSymbolIndex implementation;

    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;

    address owner = makeAddr("owner");
    address writer = makeAddr("writer");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    event AddressKey(bytes32 indexed _symbol, address _token);
    event AddressAdded(address _token);
    event AddressRemoved(address _token);
    event WriterAdded(address _writer);
    event WriterDeleted(address _writer);

    function setUp() public {
        implementation = new TokenUniqueSymbolIndex();
        address payable indexAddress = payable(LibClone.clone(address(implementation)));
        index = TokenUniqueSymbolIndex(indexAddress);

        tokenA = new MockToken("Token A", "TKA");
        tokenB = new MockToken("Token B", "TKB");
        tokenC = new MockToken("Token C", "TKC");

        bytes32[] memory symbols = new bytes32[](0);
        address[] memory tokensArr = new address[](0);
        index.initialize(owner, tokensArr, symbols);

        vm.prank(owner);
        index.addWriter(writer);
    }

    function test_getters() public view {
        assertEq(index.owner(), owner);
        assertEq(index.entryCount(), 0);
    }

    function test_initialize_with_tokens() public {
        TokenUniqueSymbolIndex newIndex = TokenUniqueSymbolIndex(
            payable(LibClone.clone(address(implementation)))
        );

        bytes32[] memory symbols = new bytes32[](2);
        address[] memory tokensArr = new address[](2);
        symbols[0] = bytes32(bytes("TKA"));
        symbols[1] = bytes32(bytes("TKB"));
        tokensArr[0] = address(tokenA);
        tokensArr[1] = address(tokenB);

        newIndex.initialize(owner, tokensArr, symbols);

        assertEq(newIndex.entryCount(), 2);
        assertEq(newIndex.entry(0), address(tokenA));
        assertEq(newIndex.entry(1), address(tokenB));
        assertTrue(newIndex.have(address(tokenA)));
    }

    function test_register() public {
        vm.expectEmit(true, false, false, true);
        emit AddressAdded(address(tokenA));

        vm.prank(writer);
        bool success = index.register(address(tokenA));

        assertTrue(success);
        assertEq(index.entryCount(), 1);
        assertEq(index.entry(0), address(tokenA));
        assertTrue(index.have(address(tokenA)));
        assertEq(index.tokenIndex(address(tokenA)), bytes32(bytes("TKA")));
    }

    function test_register_revertIf_symbol_exists() public {
        vm.prank(writer);
        index.register(address(tokenA));

        MockToken duplicate = new MockToken("Token A Duplicate", "TKA");

        vm.prank(writer);
        vm.expectRevert(SymbolAlreadyExists.selector);
        index.register(address(duplicate));
    }

    function test_register_revertIf_not_authorized() public {
        vm.prank(user1);
        vm.expectRevert(Access.selector);
        index.register(address(tokenA));
    }

    function test_register_revertIf_symbol_too_long() public {
        string memory longSymbol = "THIS_SYMBOL_IS_WAY_TOO_LONG_FOR_BYTES32";
        MockToken longToken = new MockToken("Very Long Symbol", longSymbol);

        vm.prank(writer);
        vm.expectRevert(TokenSymbolTooLong.selector);
        index.register(address(longToken));
    }

    function test_add_multiple() public {
        vm.startPrank(writer);
        index.add(address(tokenA));
        index.add(address(tokenB));
        index.add(address(tokenC));
        vm.stopPrank();

        assertEq(index.entryCount(), 3);
        assertEq(index.entry(0), address(tokenA));
        assertEq(index.entry(1), address(tokenB));
        assertEq(index.entry(2), address(tokenC));
    }

    function test_remove() public {
        vm.prank(writer);
        index.add(address(tokenA));
        index.add(address(tokenB));

        vm.expectEmit(true, false, false, true);
        emit AddressRemoved(address(tokenA));

        vm.prank(writer);
        bool success = index.remove(address(tokenA));

        assertTrue(success);
        assertEq(index.entryCount(), 1);
        assertFalse(index.have(address(tokenA)));
        assertTrue(index.have(address(tokenB)));
    }

    function test_remove_revertIf_not_authorized() public {
        vm.prank(writer);
        index.add(address(tokenA));

        vm.prank(user1);
        vm.expectRevert(Access.selector);
        index.remove(address(tokenA));
    }

    function test_remove_revertIf_not_found() public {
        vm.prank(writer);
        vm.expectRevert(NotFound.selector);
        index.remove(address(tokenA));
    }

    function test_remove_swap_last() public {
        vm.startPrank(writer);
        index.add(address(tokenA));
        index.add(address(tokenB));
        index.add(address(tokenC));
        vm.stopPrank();

        assertEq(index.entry(0), address(tokenA));
        assertEq(index.entry(1), address(tokenB));
        assertEq(index.entry(2), address(tokenC));

        vm.prank(writer);
        index.remove(address(tokenA));

        assertEq(index.entryCount(), 2);
        assertEq(index.entry(0), address(tokenC));
        assertEq(index.entry(1), address(tokenB));
    }

    function test_time() public view {
        uint256 time = index.time(address(tokenA));
        assertEq(time, 0);
    }

    function test_activate() public view {
        bool active = index.activate(address(tokenA));
        assertFalse(active);
    }

    function test_deactivate() public view {
        bool active = index.deactivate(address(tokenA));
        assertFalse(active);
    }

    function test_entry() public {
        vm.prank(writer);
        index.add(address(tokenA));
        index.add(address(tokenB));

        assertEq(index.entry(0), address(tokenA));
        assertEq(index.entry(1), address(tokenB));
    }

    function test_addressOf() public {
        vm.prank(writer);
        index.add(address(tokenA));

        bytes32 symbolKey = bytes32(bytes("TKA"));
        assertEq(index.addressOf(symbolKey), address(tokenA));
    }

    function test_identifier() public {
        vm.prank(writer);
        index.add(address(tokenA));

        bytes32 symbolKey = bytes32(bytes("TKA"));
        assertEq(index.identifier(0), symbolKey);
    }

    function test_identifierCount() public {
        assertEq(index.identifierCount(), 0);

        vm.prank(writer);
        index.add(address(tokenA));

        assertEq(index.identifierCount(), 1);
    }

    function test_have() public {
        assertFalse(index.have(address(tokenA)));

        vm.prank(writer);
        index.add(address(tokenA));

        assertTrue(index.have(address(tokenA)));
    }

    function test_addWriter() public {
        address newWriter = makeAddr("newWriter");

        vm.expectEmit(true, false, false, true);
        emit WriterAdded(newWriter);

        vm.prank(owner);
        bool success = index.addWriter(newWriter);

        assertTrue(success);
        assertTrue(index.isWriter(newWriter));
    }

    function test_addWriter_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        index.addWriter(user2);
    }

    function test_deleteWriter() public {
        vm.expectEmit(true, false, false, true);
        emit WriterDeleted(writer);

        vm.prank(owner);
        bool success = index.deleteWriter(writer);

        assertTrue(success);
        assertFalse(index.isWriter(writer));
    }

    function test_deleteWriter_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        index.deleteWriter(writer);
    }

    function test_supportsInterface() public view {
        assertTrue(index.supportsInterface(0xeffbf671));
        assertTrue(index.supportsInterface(0xb7bca625));
        assertTrue(index.supportsInterface(0x9479f0ae));
        assertTrue(index.supportsInterface(0x01ffc9a7));
        assertTrue(index.supportsInterface(0x9493f8b2));
        assertTrue(index.supportsInterface(0x80c84bd6));
        assertFalse(index.supportsInterface(0xffffffff));
    }
}

contract MockToken {
    string public name;
    string public symbol;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }
}
