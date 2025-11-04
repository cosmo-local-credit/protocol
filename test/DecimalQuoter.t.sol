// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/DecimalQuoter.sol";
import "../src/interfaces/IERC20Meta.sol";

contract DecimalQuoterTest is Test {
    DecimalQuoter quoter;

    MockToken token6Decimals;
    MockToken token18Decimals;
    MockToken token8Decimals;
    MockToken anotherToken6Decimals;

    function setUp() public {
        quoter = new DecimalQuoter();

        token6Decimals = new MockToken("Token 6", "TK6", 6);
        token18Decimals = new MockToken("Token 18", "TK18", 18);
        token8Decimals = new MockToken("Token 8", "TK8", 8);
        anotherToken6Decimals = new MockToken("Another Token 6", "ATK6", 6);
    }

    function test_valueFor_same_decimals() public view {
        uint256 value = 1000e6;
        uint256 result = quoter.valueFor(
            address(token6Decimals),
            address(anotherToken6Decimals),
            value
        );
        assertEq(result, value);
    }

    function test_valueFor_inToken_higher_decimals() public view {
        uint256 value = 1000e18;
        uint256 result = quoter.valueFor(
            address(token6Decimals),
            address(token18Decimals),
            value
        );
        assertEq(result, 1000e6);
    }

    function test_valueFor_outToken_higher_decimals() public view {
        uint256 value = 1000e6;
        uint256 result = quoter.valueFor(
            address(token18Decimals),
            address(token6Decimals),
            value
        );
        assertEq(result, 1000e18);
    }

    function test_valueFor_8_to_6_decimals() public view {
        uint256 value = 1000e8;
        uint256 result = quoter.valueFor(
            address(token6Decimals),
            address(token8Decimals),
            value
        );
        assertEq(result, 1000e6);
    }

    function test_valueFor_6_to_8_decimals() public view {
        uint256 value = 1000e6;
        uint256 result = quoter.valueFor(
            address(token8Decimals),
            address(token6Decimals),
            value
        );
        assertEq(result, 1000e8);
    }

    function test_valueFor_precision_loss() public view {
        uint256 value = 123;
        uint256 result = quoter.valueFor(
            address(token6Decimals),
            address(token18Decimals),
            value
        );
        assertEq(result, 0);
    }

    function test_valueFor_large_numbers() public view {
        uint256 value = type(uint128).max;
        uint256 result = quoter.valueFor(
            address(token6Decimals),
            address(token18Decimals),
            value
        );
        assertEq(result, value / 1e12);
    }

    function testFuzz_valueFor_same_decimals(uint256 value) public view {
        vm.assume(value < type(uint256).max / 1e18);
        uint256 result = quoter.valueFor(
            address(token6Decimals),
            address(anotherToken6Decimals),
            value
        );
        assertEq(result, value);
    }

    function testFuzz_valueFor_up_then_down(uint256 value) public view {
        vm.assume(value < type(uint128).max);
        vm.assume(value % 1e12 == 0);

        uint256 upConverted = quoter.valueFor(
            address(token18Decimals),
            address(token6Decimals),
            value
        );

        uint256 downConverted = quoter.valueFor(
            address(token6Decimals),
            address(token18Decimals),
            upConverted
        );

        assertEq(downConverted, value);
    }
}

// Mock ERC20 token with configurable decimals
contract MockToken is IERC20Meta {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }
}
