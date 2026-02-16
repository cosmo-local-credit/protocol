// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/PeriodSimple.sol";

contract PeriodSimpleTest is Test {
    using LibClone for address;

    error Access();
    error Unauthorized();

    PeriodSimple periodChecker;
    PeriodSimple implementation;

    address owner = makeAddr("owner");
    address poker = makeAddr("poker");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    event PeriodChange(uint256 _value);
    event BalanceThresholdChange(uint256 _value);

    function setUp() public {
        implementation = new PeriodSimple();
        address checkerAddress = LibClone.clone(address(implementation));
        periodChecker = PeriodSimple(checkerAddress);

        periodChecker.initialize(owner, poker);
    }

    function test_getters() public view {
        assertEq(periodChecker.owner(), owner);
        assertEq(periodChecker.poker(), poker);
        assertEq(periodChecker.period(), 0);
        assertEq(periodChecker.balanceThreshold(), 0);
    }

    function test_setPeriod() public {
        uint256 newPeriod = 3600;

        vm.expectEmit(false, false, false, true);
        emit PeriodChange(newPeriod);

        vm.prank(owner);
        periodChecker.setPeriod(newPeriod);

        assertEq(periodChecker.period(), newPeriod);
    }

    function test_setPeriod_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        periodChecker.setPeriod(3600);
    }

    function test_setPoker() public {
        address newPoker = makeAddr("newPoker");

        vm.prank(owner);
        periodChecker.setPoker(newPoker);

        assertEq(periodChecker.poker(), newPoker);
    }

    function test_setPoker_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        periodChecker.setPoker(makeAddr("poker"));
    }

    function test_setBalanceThreshold() public {
        uint256 threshold = 1 ether;

        vm.expectEmit(false, false, false, true);
        emit BalanceThresholdChange(threshold);

        vm.prank(owner);
        periodChecker.setBalanceThreshold(threshold);

        assertEq(periodChecker.balanceThreshold(), threshold);
    }

    function test_setBalanceThreshold_revertIf_not_owner() public {
        vm.prank(user1);
        vm.expectRevert(Unauthorized.selector);
        periodChecker.setBalanceThreshold(1 ether);
    }

    function test_have_first_use() public view {
        assertTrue(periodChecker.have(user1));
    }

    function test_have_after_period() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);

        vm.prank(owner);
        periodChecker.poke(user1);

        skip(3601);

        assertTrue(periodChecker.have(user1));
    }

    function test_have_within_period() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);

        vm.prank(owner);
        periodChecker.poke(user1);

        skip(1800);

        assertFalse(periodChecker.have(user1));
    }

    function test_have_with_balance_threshold() public {
        vm.prank(owner);
        periodChecker.setBalanceThreshold(1 ether);

        vm.deal(user1, 0.5 ether);
        assertTrue(periodChecker.have(user1));

        vm.deal(user2, 2 ether);
        assertFalse(periodChecker.have(user2));
    }

    function test_have_balance_threshold_zero() public {
        vm.prank(owner);
        periodChecker.setBalanceThreshold(0);

        vm.deal(user1, 100 ether);
        assertTrue(periodChecker.have(user1));
    }

    function test_have_combined() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);
        vm.prank(owner);
        periodChecker.setBalanceThreshold(1 ether);

        vm.deal(user1, 0.5 ether);

        vm.prank(owner);
        periodChecker.poke(user1);

        assertFalse(periodChecker.have(user1));

        skip(3601);

        assertTrue(periodChecker.have(user1));
    }

    function test_poke_by_owner() public {
        vm.prank(owner);
        bool result = periodChecker.poke(user1);

        assertTrue(result);
        assertEq(periodChecker.lastUsed(user1), block.timestamp);
    }

    function test_poke_by_poker() public {
        vm.prank(poker);
        bool result = periodChecker.poke(user1);

        assertTrue(result);
        assertEq(periodChecker.lastUsed(user1), block.timestamp);
    }

    function test_poke_revertIf_not_authorized() public {
        vm.prank(user1);
        vm.expectRevert(Access.selector);
        periodChecker.poke(user2);
    }

    function test_poke_returnsFalse_if_not_eligible() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);

        vm.prank(owner);
        periodChecker.poke(user1);

        skip(1800);

        vm.prank(owner);
        bool result = periodChecker.poke(user1);

        assertFalse(result);
    }

    function test_poke_returnsFalse_with_balance_threshold() public {
        vm.prank(owner);
        periodChecker.setBalanceThreshold(1 ether);

        vm.deal(user1, 2 ether);

        vm.prank(owner);
        bool result = periodChecker.poke(user1);

        assertFalse(result);
    }

    function test_next() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);

        uint256 lastUsed = block.timestamp;
        vm.prank(owner);
        periodChecker.poke(user1);

        uint256 nextTime = periodChecker.next(user1);
        assertEq(nextTime, lastUsed + 3600);
    }

    function test_next_first_use() public {
        uint256 nextTime = periodChecker.next(user1);
        assertEq(nextTime, 0);
    }

    function test_next_zero_period() public {
        vm.prank(owner);
        periodChecker.poke(user1);

        uint256 nextTime = periodChecker.next(user1);
        assertEq(nextTime, block.timestamp);
    }

    function test_multiple_users() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);

        vm.prank(owner);
        periodChecker.poke(user1);
        vm.prank(owner);
        periodChecker.poke(user2);
        vm.prank(owner);
        periodChecker.poke(user3);

        skip(3601);

        assertTrue(periodChecker.have(user1));
        assertTrue(periodChecker.have(user2));
        assertTrue(periodChecker.have(user3));
    }

    function test_poke_independent_users() public {
        vm.prank(owner);
        periodChecker.setPeriod(3600);

        vm.prank(owner);
        periodChecker.poke(user1);
        skip(1800);

        assertFalse(periodChecker.have(user1));
        assertTrue(periodChecker.have(user2));
    }

    function test_supportsInterface() public view {
        assertTrue(periodChecker.supportsInterface(0x01ffc9a7));
        assertTrue(periodChecker.supportsInterface(0x9493f8b2));
        assertTrue(periodChecker.supportsInterface(0x3ef25013));
        assertTrue(periodChecker.supportsInterface(0x242824a9));
        assertFalse(periodChecker.supportsInterface(0xffffffff));
    }

    function test_fuzz_setPeriod(uint256 period) public {
        vm.assume(period < 365 days);

        vm.prank(owner);
        periodChecker.setPeriod(period);

        assertEq(periodChecker.period(), period);
    }

    function test_fuzz_setBalanceThreshold(uint256 threshold) public {
        vm.assume(threshold < 1000 ether);

        vm.prank(owner);
        periodChecker.setBalanceThreshold(threshold);

        assertEq(periodChecker.balanceThreshold(), threshold);
    }

    function test_fuzz_poke(uint256 period, uint256 elapsed) public {
        vm.assume(period > 0 && period < 365 days);
        vm.assume(elapsed < 2 * period);

        vm.prank(owner);
        periodChecker.setPeriod(period);

        vm.prank(owner);
        periodChecker.poke(user1);

        skip(elapsed);

        bool have = periodChecker.have(user1);
        assertEq(have, elapsed > period);
    }

    function test_edge_case_period_zero() public {
        vm.prank(owner);
        periodChecker.setPeriod(0);

        vm.prank(owner);
        periodChecker.poke(user1);

        skip(1);
        assertTrue(periodChecker.have(user1));
    }

    function test_edge_case_large_threshold() public {
        vm.prank(owner);
        periodChecker.setBalanceThreshold(type(uint256).max);

        vm.deal(user1, type(uint256).max);
        assertFalse(periodChecker.have(user1));
    }
}
