// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/AccountsIndex.sol";

contract AccountsIndexTest is Test {
    using LibClone for address;

    error Access();
    error AlreadyExists();
    error NotFound();
    error NotBlocked();
    error NotActive();
    error IndexFull();
    error Unauthorized();

    AccountsIndex index;
    AccountsIndex implementation;

    address owner = makeAddr("owner");
    address writer = makeAddr("writer");
    address account1 = makeAddr("account1");
    address account2 = makeAddr("account2");
    address account3 = makeAddr("account3");

    event AddressAdded(address _account);
    event AddressActive(address indexed _account, bool _active);
    event AddressRemoved(address _account);
    event WriterAdded(address _account);
    event WriterDeleted(address _account);

    function setUp() public {
        implementation = new AccountsIndex();
        address payable indexAddress = payable(LibClone.clone(address(implementation)));
        index = AccountsIndex(indexAddress);

        index.initialize(owner);
        vm.prank(owner);
        index.addWriter(writer);
    }

    function test_getters() public view {
        assertEq(index.owner(), owner);
        assertEq(index.entryCount(), 0);
        assertTrue(index.isWriter(writer));
        assertTrue(index.isWriter(owner));
    }

    function test_add() public {
        vm.expectEmit(true, false, false, true);
        emit AddressAdded(account1);

        vm.prank(writer);
        bool success = index.add(account1);

        assertTrue(success);
        assertEq(index.entryCount(), 1);
        assertEq(index.entry(0), account1);
        assertTrue(index.have(account1));
    }

    function test_add_multiple() public {
        vm.startPrank(writer);
        index.add(account1);
        index.add(account2);
        index.add(account3);
        vm.stopPrank();

        assertEq(index.entryCount(), 3);
        assertEq(index.entry(0), account1);
        assertEq(index.entry(1), account2);
        assertEq(index.entry(2), account3);
    }

    function test_add_revertIf_not_authorized() public {
        vm.prank(account1);
        vm.expectRevert(Access.selector);
        index.add(account2);
    }

    function test_add_revertIf_already_exists() public {
        vm.prank(writer);
        index.add(account1);

        vm.prank(writer);
        vm.expectRevert(AlreadyExists.selector);
        index.add(account1);
    }

    function test_remove() public {
        vm.startPrank(writer);
        index.add(account1);
        index.add(account2);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit AddressRemoved(account1);

        vm.prank(writer);
        bool success = index.remove(account1);

        assertTrue(success);
        assertEq(index.entryCount(), 1);
        assertFalse(index.have(account1));
        assertTrue(index.have(account2));
    }

    function test_remove_revertIf_not_authorized() public {
        vm.prank(writer);
        index.add(account1);

        vm.prank(account1);
        vm.expectRevert(Access.selector);
        index.remove(account1);
    }

    function test_remove_revertIf_not_found() public {
        vm.prank(writer);
        vm.expectRevert(AlreadyExists.selector);
        index.remove(account1);
    }

    function test_remove_swap_last() public {
        vm.startPrank(writer);
        index.add(account1);
        index.add(account2);
        index.add(account3);
        vm.stopPrank();

        assertEq(index.entry(0), account1);
        assertEq(index.entry(1), account2);
        assertEq(index.entry(2), account3);

        vm.prank(writer);
        index.remove(account3);

        assertEq(index.entryCount(), 2);
        assertEq(index.entry(0), account1);
        assertEq(index.entry(1), account2);
    }

    function test_activate() public {
        vm.prank(writer);
        index.add(account1);

        vm.prank(writer);
        index.deactivate(account1);

        assertFalse(index.isActive(account1));

        vm.expectEmit(true, false, false, true);
        emit AddressActive(account1, true);

        vm.prank(writer);
        bool success = index.activate(account1);

        assertTrue(success);
        assertTrue(index.isActive(account1));
    }

    function test_activate_revertIf_not_authorized() public {
        vm.prank(writer);
        index.add(account1);
        vm.prank(writer);
        index.deactivate(account1);

        vm.prank(account1);
        vm.expectRevert(Access.selector);
        index.activate(account1);
    }

    function test_activate_revertIf_not_found() public {
        vm.prank(writer);
        vm.expectRevert(NotFound.selector);
        index.activate(account1);
    }

    function test_activate_revertIf_not_blocked() public {
        vm.prank(writer);
        index.add(account1);

        vm.prank(writer);
        vm.expectRevert(NotBlocked.selector);
        index.activate(account1);
    }

    function test_deactivate() public {
        vm.prank(writer);
        index.add(account1);

        assertTrue(index.isActive(account1));

        vm.expectEmit(true, false, false, true);
        emit AddressActive(account1, false);

        vm.prank(writer);
        bool success = index.deactivate(account1);

        assertTrue(success);
        assertFalse(index.isActive(account1));
    }

    function test_deactivate_revertIf_not_authorized() public {
        vm.prank(writer);
        index.add(account1);

        vm.prank(account1);
        vm.expectRevert(Access.selector);
        index.deactivate(account1);
    }

    function test_deactivate_revertIf_not_found() public {
        vm.prank(writer);
        vm.expectRevert(NotFound.selector);
        index.deactivate(account1);
    }

    function test_deactivate_revertIf_not_active() public {
        vm.prank(writer);
        index.add(account1);
        vm.prank(writer);
        index.deactivate(account1);

        vm.prank(writer);
        vm.expectRevert(NotActive.selector);
        index.deactivate(account1);
    }

    function test_entry() public {
        vm.startPrank(writer);
        index.add(account1);
        index.add(account2);
        vm.stopPrank();

        assertEq(index.entry(0), account1);
        assertEq(index.entry(1), account2);
    }

    function test_time() public {
        uint256 beforeTime = block.timestamp;

        vm.prank(writer);
        index.add(account1);

        uint256 afterTime = block.timestamp;
        uint256 accountTime = index.time(account1);

        assertTrue(accountTime >= beforeTime && accountTime <= afterTime);
    }

    function test_have() public {
        assertFalse(index.have(account1));

        vm.prank(writer);
        index.add(account1);

        assertTrue(index.have(account1));
    }

    function test_isActive() public {
        vm.prank(writer);
        index.add(account1);

        assertTrue(index.isActive(account1));

        vm.prank(writer);
        index.deactivate(account1);

        assertFalse(index.isActive(account1));
    }

    function test_entryCount() public {
        assertEq(index.entryCount(), 0);

        vm.prank(writer);
        index.add(account1);

        assertEq(index.entryCount(), 1);
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
        vm.prank(account1);
        vm.expectRevert(Unauthorized.selector);
        index.addWriter(account2);
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
        vm.prank(account1);
        vm.expectRevert(Unauthorized.selector);
        index.deleteWriter(writer);
    }

    function test_isWriter() public view {
        assertTrue(index.isWriter(writer));
        assertTrue(index.isWriter(owner));
        assertFalse(index.isWriter(account1));
    }

    function test_supportsInterface() public view {
        assertTrue(index.supportsInterface(0xb7bca625));
        assertTrue(index.supportsInterface(0x9479f0ae));
        assertTrue(index.supportsInterface(0x01ffc9a7));
        assertTrue(index.supportsInterface(0x9493f8b2));
        assertTrue(index.supportsInterface(0xabe1f1f5));
        assertFalse(index.supportsInterface(0xffffffff));
    }

    function test_fuzz_add(address account) public {
        vm.assume(account != address(0));
        vm.assume(account != writer);

        vm.prank(writer);
        index.add(account);

        assertTrue(index.have(account));
    }

    function test_fuzz_time(address account) public {
        vm.assume(account != address(0));

        uint256 beforeTime = block.timestamp;

        vm.prank(writer);
        index.add(account);

        uint256 afterTime = block.timestamp;
        uint256 accountTime = index.time(account);

        assertTrue(accountTime >= beforeTime && accountTime <= afterTime);
    }

    function test_multiple_activation_cycles() public {
        vm.prank(writer);
        index.add(account1);

        assertTrue(index.isActive(account1));

        vm.startPrank(writer);
        index.deactivate(account1);
        assertFalse(index.isActive(account1));

        index.activate(account1);
        assertTrue(index.isActive(account1));

        index.deactivate(account1);
        assertFalse(index.isActive(account1));

        index.activate(account1);
        assertTrue(index.isActive(account1));
        vm.stopPrank();
    }

    function test_independent_accounts() public {
        vm.startPrank(writer);
        index.add(account1);
        index.add(account2);
        vm.stopPrank();

        vm.prank(writer);
        index.deactivate(account1);

        assertTrue(index.have(account1));
        assertTrue(index.have(account2));
        assertFalse(index.isActive(account1));
        assertTrue(index.isActive(account2));
    }
}
