// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/ProtocolFeeController.sol";

contract ProtocolFeeControllerTest is Test {
    using LibClone for address;

    error InvalidInitialization();
    error InvalidFee();
    error InvalidRecipient();

    ProtocolFeeController controller;
    ProtocolFeeController implementation;

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");

    uint256 constant PPM = 1_000_000;

    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ActiveStateUpdated(bool active);

    function setUp() public {
        implementation = new ProtocolFeeController();
        address controllerAddress = LibClone.clone(address(implementation));
        controller = ProtocolFeeController(controllerAddress);
        controller.initialize(owner, 100_000, recipient);
    }

    function test_initialize() public view {
        assertEq(controller.owner(), owner);
        assertEq(controller.getProtocolFee(), 100_000);
        assertEq(controller.getProtocolFeeRecipient(), recipient);
        assertTrue(controller.isActive());
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        controller.initialize(owner, 100_000, recipient);
    }

    function test_initialize_revertIf_invalidFee() public {
        address controllerAddress = LibClone.clone(address(implementation));
        ProtocolFeeController newController = ProtocolFeeController(controllerAddress);

        vm.expectRevert(InvalidFee.selector);
        newController.initialize(owner, PPM + 1, recipient);
    }

    function test_initialize_revertIf_invalidRecipient() public {
        address controllerAddress = LibClone.clone(address(implementation));
        ProtocolFeeController newController = ProtocolFeeController(controllerAddress);

        vm.expectRevert(InvalidRecipient.selector);
        newController.initialize(owner, 100_000, address(0));
    }

    function test_getProtocolFee_returnsZeroWhenInactive() public {
        vm.prank(owner);
        controller.setActive(false);

        assertEq(controller.getProtocolFee(), 0);
    }

    function test_getProtocolFee_returnsConfiguredWhenActive() public view {
        assertEq(controller.getProtocolFee(), 100_000);
    }

    function test_setProtocolFee() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(100_000, 250_000);
        controller.setProtocolFee(250_000);

        assertEq(controller.getProtocolFee(), 250_000);
    }

    function test_setProtocolFee_revertIf_invalid() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFee.selector);
        controller.setProtocolFee(PPM + 1);
    }

    function test_setProtocolFee_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setProtocolFee(250_000);
    }

    function test_setProtocolFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ProtocolFeeRecipientUpdated(recipient, newRecipient);
        controller.setProtocolFeeRecipient(newRecipient);

        assertEq(controller.getProtocolFeeRecipient(), newRecipient);
    }

    function test_setProtocolFeeRecipient_revertIf_zero() public {
        vm.prank(owner);
        vm.expectRevert(InvalidRecipient.selector);
        controller.setProtocolFeeRecipient(address(0));
    }

    function test_setProtocolFeeRecipient_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setProtocolFeeRecipient(makeAddr("newRecipient"));
    }

    function test_setActive_false() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ActiveStateUpdated(false);
        controller.setActive(false);

        assertFalse(controller.isActive());
        assertEq(controller.getProtocolFee(), 0);
    }

    function test_setActive_true() public {
        vm.startPrank(owner);
        controller.setActive(false);

        vm.expectEmit(false, false, false, true);
        emit ActiveStateUpdated(true);
        controller.setActive(true);
        vm.stopPrank();

        assertTrue(controller.isActive());
        assertEq(controller.getProtocolFee(), 100_000);
    }

    function test_setActive_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        controller.setActive(false);
    }
}
