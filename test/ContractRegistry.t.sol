// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/ContractRegistry.sol";

contract ContractRegistryTest is Test {
    using LibClone for address;

    error IdentifierAlreadyExists();
    error IdentifierNotFound();
    error ZeroAddress();
    error Unauthorized();

    ContractRegistry registry;
    ContractRegistry implementation;

    address owner = makeAddr("owner");
    address contractA = makeAddr("contractA");
    address contractB = makeAddr("contractB");
    address contractC = makeAddr("contractC");

    bytes32 constant KEY_A = keccak256(abi.encodePacked(bytes("ContractA")));
    bytes32 constant KEY_B = keccak256(abi.encodePacked(bytes("ContractB")));
    bytes32 constant KEY_C = keccak256(abi.encodePacked(bytes("ContractC")));

    event AddressKey(bytes32 indexed _key, address _address);

    function setUp() public {
        implementation = new ContractRegistry();
        address payable registryAddress = payable(LibClone.clone(address(implementation)));
        registry = ContractRegistry(registryAddress);

        bytes32[] memory identifiers = new bytes32[](3);
        identifiers[0] = KEY_A;
        identifiers[1] = KEY_B;
        identifiers[2] = KEY_C;

        registry.initialize(owner, identifiers);
    }

    function test_getters() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.identifierCount(), 3);
        assertEq(registry.identifier(0), KEY_A);
        assertEq(registry.identifier(1), KEY_B);
        assertEq(registry.identifier(2), KEY_C);
    }

    function test_initialize_with_identifiers() public {
        ContractRegistry newRegistry = ContractRegistry(
            payable(LibClone.clone(address(implementation)))
        );

        bytes32[] memory identifiers = new bytes32[](2);
        identifiers[0] = KEY_A;
        identifiers[1] = KEY_B;

        newRegistry.initialize(owner, identifiers);

        assertEq(newRegistry.identifierCount(), 2);
        assertEq(newRegistry.identifier(0), KEY_A);
        assertEq(newRegistry.identifier(1), KEY_B);
    }

    function test_set() public {
        vm.expectEmit(true, true, false, true);
        emit AddressKey(KEY_A, contractA);

        vm.prank(owner);
        bool success = registry.set(KEY_A, contractA);

        assertTrue(success);
        assertEq(registry.addressOf(KEY_A), contractA);
    }

    function test_set_multiple() public {
        vm.startPrank(owner);
        registry.set(KEY_A, contractA);
        registry.set(KEY_B, contractB);
        registry.set(KEY_C, contractC);
        vm.stopPrank();

        assertEq(registry.addressOf(KEY_A), contractA);
        assertEq(registry.addressOf(KEY_B), contractB);
        assertEq(registry.addressOf(KEY_C), contractC);
    }

    function test_set_revertIf_not_owner() public {
        vm.prank(contractA);
        vm.expectRevert(Unauthorized.selector);
        registry.set(KEY_A, contractA);
    }

    function test_set_revertIf_already_exists() public {
        vm.prank(owner);
        registry.set(KEY_A, contractA);

        vm.prank(owner);
        vm.expectRevert(IdentifierAlreadyExists.selector);
        registry.set(KEY_A, contractB);
    }

    function test_set_revertIf_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        registry.set(KEY_A, address(0));
    }

    function test_set_revertIf_identifier_not_found() public {
        bytes32 invalidKey = keccak256(abi.encodePacked(bytes("Invalid")));

        vm.prank(owner);
        vm.expectRevert(IdentifierNotFound.selector);
        registry.set(invalidKey, contractA);
    }

    function test_addressOf() public {
        vm.prank(owner);
        registry.set(KEY_A, contractA);

        assertEq(registry.addressOf(KEY_A), contractA);
        assertEq(registry.addressOf(KEY_B), address(0));
    }

    function test_identifier() public view {
        assertEq(registry.identifier(0), KEY_A);
        assertEq(registry.identifier(1), KEY_B);
        assertEq(registry.identifier(2), KEY_C);
    }

    function test_identifierCount() public view {
        assertEq(registry.identifierCount(), 3);
    }

    function test_supportsInterface() public view {
        assertTrue(registry.supportsInterface(0xeffbf671));
        assertTrue(registry.supportsInterface(0x01ffc9a7));
        assertTrue(registry.supportsInterface(0x9493f8b2));
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    function test_fuzz_set_address(address addr) public {
        vm.assume(addr != address(0));

        vm.prank(owner);
        registry.set(KEY_A, addr);

        assertEq(registry.addressOf(KEY_A), addr);
    }

    function test_fuzz_initialize_identifiers_count(uint256 count) public {
        vm.assume(count > 0 && count < 100);

        bytes32[] memory identifiers = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            identifiers[i] = keccak256(abi.encodePacked(i));
        }

        ContractRegistry newRegistry = ContractRegistry(
            payable(LibClone.clone(address(implementation)))
        );

        newRegistry.initialize(owner, identifiers);

        assertEq(newRegistry.identifierCount(), count);
    }
}
