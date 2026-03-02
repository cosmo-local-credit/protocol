// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/FeePolicy.sol";

contract FeePolicyTest is Test {
    using LibClone for address;

    error InvalidInitialization();
    error InvalidFee();
    error InvalidToken();

    FeePolicy policy;
    FeePolicy implementation;

    address owner = makeAddr("owner");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");
    address tokenC = makeAddr("tokenC");

    uint256 constant PPM = 1_000_000;

    event DefaultFeeUpdated(uint256 oldFee, uint256 newFee);
    event PairFeeUpdated(address indexed tokenIn, address indexed tokenOut, uint256 oldFee, uint256 newFee);
    event PairFeeRemoved(address indexed tokenIn, address indexed tokenOut);

    function setUp() public {
        implementation = new FeePolicy();
        address policyAddress = LibClone.clone(address(implementation));
        policy = FeePolicy(policyAddress);
        policy.initialize(owner, 10_000);
    }

    function test_initialize() public view {
        assertEq(policy.owner(), owner);
        assertEq(policy.getDefaultFee(), 10_000);
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        policy.initialize(owner, 10_000);
    }

    function test_initialize_revertIf_invalidDefaultFee() public {
        address policyAddress = LibClone.clone(address(implementation));
        FeePolicy newPolicy = FeePolicy(policyAddress);

        vm.expectRevert(InvalidFee.selector);
        newPolicy.initialize(owner, PPM + 1);
    }

    function test_getFee_returnsDefaultIfPairNotSet() public view {
        assertEq(policy.getFee(tokenA, tokenB), 10_000);
    }

    function test_getFee_returnsPairFeeIfSet() public {
        vm.prank(owner);
        policy.setPairFee(tokenA, tokenB, 25_000);

        assertEq(policy.getFee(tokenA, tokenB), 25_000);
    }

    function test_getFee_directional() public {
        vm.prank(owner);
        policy.setPairFee(tokenA, tokenB, 25_000);

        assertEq(policy.getFee(tokenA, tokenB), 25_000);
        assertEq(policy.getFee(tokenB, tokenA), 10_000);
    }

    function test_setDefaultFee() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit DefaultFeeUpdated(10_000, 20_000);
        policy.setDefaultFee(20_000);

        assertEq(policy.getDefaultFee(), 20_000);
    }

    function test_setDefaultFee_revertIf_invalid() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFee.selector);
        policy.setDefaultFee(PPM + 1);
    }

    function test_setDefaultFee_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        policy.setDefaultFee(20_000);
    }

    function test_setPairFee() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit PairFeeUpdated(tokenA, tokenB, 10_000, 30_000);
        policy.setPairFee(tokenA, tokenB, 30_000);

        assertEq(policy.getFee(tokenA, tokenB), 30_000);
    }

    function test_setPairFee_updateExisting() public {
        vm.startPrank(owner);
        policy.setPairFee(tokenA, tokenB, 30_000);

        vm.expectEmit(true, true, false, true);
        emit PairFeeUpdated(tokenA, tokenB, 30_000, 40_000);
        policy.setPairFee(tokenA, tokenB, 40_000);
        vm.stopPrank();

        assertEq(policy.getFee(tokenA, tokenB), 40_000);
    }

    function test_setPairFee_revertIf_invalidToken() public {
        vm.prank(owner);
        vm.expectRevert(InvalidToken.selector);
        policy.setPairFee(address(0), tokenB, 20_000);
    }

    function test_setPairFee_revertIf_invalidFee() public {
        vm.prank(owner);
        vm.expectRevert(InvalidFee.selector);
        policy.setPairFee(tokenA, tokenB, PPM + 1);
    }

    function test_setPairFee_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        policy.setPairFee(tokenA, tokenB, 20_000);
    }

    function test_removePairFee() public {
        vm.startPrank(owner);
        policy.setPairFee(tokenA, tokenB, 30_000);

        vm.expectEmit(true, true, false, false);
        emit PairFeeRemoved(tokenA, tokenB);
        policy.removePairFee(tokenA, tokenB);
        vm.stopPrank();

        assertEq(policy.getFee(tokenA, tokenB), 10_000);
    }

    function test_removePairFee_noopWhenMissing() public {
        vm.prank(owner);
        policy.removePairFee(tokenA, tokenB);

        assertEq(policy.getFee(tokenA, tokenB), 10_000);
    }

    function test_removePairFee_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        policy.removePairFee(tokenA, tokenB);
    }

    function test_calculateFee_usesDefault() public view {
        assertEq(policy.calculateFee(tokenA, tokenB, 100_000), 1_000);
    }

    function test_calculateFee_usesPairFee() public {
        vm.prank(owner);
        policy.setPairFee(tokenA, tokenB, 25_000);

        assertEq(policy.calculateFee(tokenA, tokenB, 100_000), 2_500);
    }

    function test_isActive() public view {
        assertTrue(policy.isActive());
    }

    function test_pairFeeIsIndependentAcrossPairs() public {
        vm.startPrank(owner);
        policy.setPairFee(tokenA, tokenB, 20_000);
        policy.setPairFee(tokenA, tokenC, 30_000);
        vm.stopPrank();

        assertEq(policy.getFee(tokenA, tokenB), 20_000);
        assertEq(policy.getFee(tokenA, tokenC), 30_000);
        assertEq(policy.getFee(tokenB, tokenC), 10_000);
    }
}
