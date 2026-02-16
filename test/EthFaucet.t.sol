// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/EthFaucet.sol";
import "../src/PeriodSimple.sol";

contract EthFaucetTest is Test {
    using LibClone for address;

    error InvalidState();
    error AlreadyLocked();
    error Sealed();
    error InsufficientBalance();
    error NotInWhitelist();
    error PeriodBackend();
    error RegistryBackend();
    error PeriodBackendError();
    error Unauthorized();

    EthFaucet faucet;
    EthFaucet implementation;

    MockRegistry registry;
    PeriodSimple periodChecker;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address unprivileged = makeAddr("unprivileged");

    event Give(address indexed _recipient, address indexed _token, uint256 _amount);
    event FaucetAmountChange(uint256 _amount);
    event SealStateChange(uint256 indexed _sealState, address _registry, address _periodChecker);

    function setUp() public {
        registry = new MockRegistry();
        periodChecker = new PeriodSimple();

        implementation = new EthFaucet();
        address payable faucetAddress = payable(LibClone.clone(address(implementation)));
        faucet = EthFaucet(faucetAddress);

        faucet.initialize(owner, 1 ether);
    }

    function test_getters() public view {
        assertEq(faucet.owner(), owner);
        assertEq(faucet.amount(), 1 ether);
        assertEq(faucet.token(), address(0));
        assertEq(faucet.sealState(), 0);
    }

    function test_setAmount() public {
        uint256 newAmount = 0.5 ether;

        vm.expectEmit(false, false, false, true);
        emit FaucetAmountChange(newAmount);

        vm.prank(owner);
        uint256 result = faucet.setAmount(newAmount);

        assertEq(result, newAmount);
        assertEq(faucet.amount(), newAmount);
    }

    function test_setAmount_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        faucet.setAmount(0.5 ether);
    }

    function test_setAmount_revertIf_sealed() public {
        vm.prank(owner);
        faucet.seal(4);

        vm.prank(owner);
        vm.expectRevert(Sealed.selector);
        faucet.setAmount(0.5 ether);
    }

    function test_setPeriodChecker() public {
        address newChecker = makeAddr("newChecker");

        vm.expectEmit(true, false, false, false);
        emit SealStateChange(faucet.sealState(), faucet.registry(), newChecker);

        vm.prank(owner);
        faucet.setPeriodChecker(newChecker);

        assertEq(faucet.periodChecker(), newChecker);
    }

    function test_setPeriodChecker_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        faucet.setPeriodChecker(makeAddr("checker"));
    }

    function test_setPeriodChecker_revertIf_sealed() public {
        vm.prank(owner);
        faucet.seal(2);

        vm.prank(owner);
        vm.expectRevert(Sealed.selector);
        faucet.setPeriodChecker(makeAddr("checker"));
    }

    function test_setRegistry() public {
        address newRegistry = makeAddr("newRegistry");

        vm.expectEmit(true, false, false, false);
        emit SealStateChange(faucet.sealState(), newRegistry, faucet.periodChecker());

        vm.prank(owner);
        faucet.setRegistry(newRegistry);

        assertEq(faucet.registry(), newRegistry);
    }

    function test_setRegistry_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        faucet.setRegistry(makeAddr("registry"));
    }

    function test_setRegistry_revertIf_sealed() public {
        vm.prank(owner);
        faucet.seal(1);

        vm.prank(owner);
        vm.expectRevert(Sealed.selector);
        faucet.setRegistry(makeAddr("registry"));
    }

    function test_seal() public {
        vm.expectEmit(true, false, false, false);
        emit SealStateChange(1, faucet.registry(), faucet.periodChecker());

        vm.prank(owner);
        uint256 result = faucet.seal(1);

        assertEq(result, 1);
        assertEq(faucet.sealState(), 1);
    }

    function test_seal_multiple() public {
        vm.startPrank(owner);
        faucet.seal(1);
        assertEq(faucet.sealState(), 1);

        faucet.seal(2);
        assertEq(faucet.sealState(), 3);

        faucet.seal(4);
        assertEq(faucet.sealState(), 7);
        vm.stopPrank();
    }

    function test_seal_revertIf_invalid_state() public {
        vm.prank(owner);
        vm.expectRevert(InvalidState.selector);
        faucet.seal(8);
    }

    function test_seal_revertIf_already_locked() public {
        vm.prank(owner);
        faucet.seal(1);

        vm.prank(owner);
        vm.expectRevert(AlreadyLocked.selector);
        faucet.seal(1);
    }

    function test_check_no_constraints() public {
        vm.deal(address(faucet), 10 ether);
        assertTrue(faucet.check(user1));
    }

    function test_check_insufficient_balance() public {
        vm.deal(address(faucet), 0.5 ether);
        assertFalse(faucet.check(user1));
    }

    function test_check_with_registry() public {
        vm.prank(owner);
        faucet.setRegistry(address(registry));
        vm.deal(address(faucet), 10 ether);

        registry.setWhitelisted(user1, true);
        assertTrue(faucet.check(user1));

        registry.setWhitelisted(user2, false);
        assertFalse(faucet.check(user2));
    }

    function test_check_with_period_checker() public {
        vm.prank(owner);
        faucet.setPeriodChecker(address(periodChecker));
        vm.deal(address(faucet), 10 ether);

        assertTrue(faucet.check(user1));
    }

    function test_gimme() public {
        vm.deal(address(faucet), 10 ether);
        uint256 balanceBefore = user1.balance;

        vm.expectEmit(true, true, false, true);
        emit Give(user1, address(0), 1 ether);

        vm.prank(user1);
        uint256 amount = faucet.gimme();

        assertEq(amount, 1 ether);
        assertEq(user1.balance, balanceBefore + 1 ether);
        assertEq(faucet.tokenAmount(), 1 ether);
    }

    function test_gimme_revertIf_insufficient_balance() public {
        vm.deal(address(faucet), 0.5 ether);

        vm.prank(user1);
        vm.expectRevert(InsufficientBalance.selector);
        faucet.gimme();
    }

    function test_gimme_with_registry() public {
        vm.prank(owner);
        faucet.setRegistry(address(registry));
        vm.deal(address(faucet), 10 ether);

        registry.setWhitelisted(user1, true);
        registry.setWhitelisted(user2, false);

        vm.prank(user1);
        faucet.gimme();

        vm.prank(user2);
        vm.expectRevert(NotInWhitelist.selector);
        faucet.gimme();
    }

    function test_giveTo() public {
        vm.deal(address(faucet), 10 ether);
        uint256 balanceBefore = user2.balance;

        vm.expectEmit(true, true, false, true);
        emit Give(user2, address(0), 1 ether);

        vm.prank(user1);
        uint256 amount = faucet.giveTo(user2);

        assertEq(amount, 1 ether);
        assertEq(user2.balance, balanceBefore + 1 ether);
    }

    function test_giveTo_revertIf_insufficient_balance() public {
        vm.deal(address(faucet), 0.5 ether);

        vm.prank(user1);
        vm.expectRevert(InsufficientBalance.selector);
        faucet.giveTo(user2);
    }

    function test_tokenAmount() public view {
        assertEq(faucet.tokenAmount(), 1 ether);
    }

    function test_supportsInterface() public view {
        assertTrue(faucet.supportsInterface(0x01ffc9a7));
        assertTrue(faucet.supportsInterface(0x9493f8b2));
        assertTrue(faucet.supportsInterface(0x1a3ac634));
        assertTrue(faucet.supportsInterface(0x0d7491f8));
        assertFalse(faucet.supportsInterface(0xffffffff));
    }

    function test_fuzz_setAmount(uint256 amount) public {
        vm.assume(amount > 0);

        vm.prank(owner);
        faucet.setAmount(amount);

        assertEq(faucet.amount(), amount);
    }

    function test_fuzz_gimme(uint256 amount, uint256 balance) public {
        vm.assume(amount > 0 && amount < 100 ether);
        vm.assume(balance > amount);

        vm.prank(owner);
        faucet.setAmount(amount);
        vm.deal(address(faucet), balance);

        uint256 balanceBefore = user1.balance;

        vm.prank(user1);
        faucet.gimme();

        assertEq(user1.balance, balanceBefore + amount);
    }
}

contract MockRegistry {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address account, bool status) external {
        whitelisted[account] = status;
    }

    function have(address account) external view returns (bool) {
        return whitelisted[account];
    }
}
