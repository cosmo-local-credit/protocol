// Author: Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	0xSplits
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISplitter} from "./interfaces/ISplitter.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract Splitter is ISplitter, Ownable, Initializable {
    uint256 public constant PERCENTAGE_SCALE = 1_000_000;

    error TooFewAccounts();
    error AccountsAndAllocationsMismatch();
    error InvalidAllocationsSum();
    error DuplicateAccount();
    error AllocationMustBePositive();
    error InvalidHash();
    error InvalidRecipient();

    bytes32 internal _splitHash;
    uint256 internal _splitVersion;
    mapping(uint256 => mapping(address => uint256)) internal _retainedAmount;
    mapping(uint256 => mapping(address => mapping(address => uint256))) internal _fractionalCarry;

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address owner, address[] calldata accounts, uint32[] calldata percentAllocations)
        external
        initializer
    {
        if (owner == address(0)) revert NewOwnerIsZeroAddress();
        _initializeOwner(owner);
        _validateSplit(accounts, percentAllocations);
        _splitHash = _hashSplit(accounts, percentAllocations);
        _splitVersion = 1;
    }

    function updateSplit(address[] calldata accounts, uint32[] calldata percentAllocations) external onlyOwner {
        _validateSplit(accounts, percentAllocations);
        _splitHash = _hashSplit(accounts, percentAllocations);
        ++_splitVersion;
    }

    function distributeETH(address[] calldata accounts, uint32[] calldata percentAllocations) external {
        _validateSplit(accounts, percentAllocations);
        _validateHash(accounts, percentAllocations);

        uint256 grossAmount = address(this).balance;
        if (grossAmount == 0) return;

        _distributeETH(grossAmount, accounts, percentAllocations);
    }

    function distributeERC20(address token, address[] calldata accounts, uint32[] calldata percentAllocations)
        external
    {
        _validateSplit(accounts, percentAllocations);
        _validateHash(accounts, percentAllocations);

        uint256 grossAmount = IERC20(token).balanceOf(address(this));
        _distributeERC20(token, grossAmount, accounts, percentAllocations);
    }

    function getHash() external view returns (bytes32) {
        return _splitHash;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == type(ISplitter).interfaceId;
    }

    function _hashSplit(address[] memory accounts, uint32[] memory percentAllocations) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(accounts, percentAllocations));
    }

    function _validateHash(address[] calldata accounts, uint32[] calldata percentAllocations) internal view {
        if (_splitHash != _hashSplit(accounts, percentAllocations)) revert InvalidHash();
    }

    function _validateSplit(address[] calldata accounts, uint32[] calldata percentAllocations) internal view {
        if (accounts.length < 2) revert TooFewAccounts();
        if (accounts.length != percentAllocations.length) revert AccountsAndAllocationsMismatch();

        uint256 sum;
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0) || accounts[i] == address(this)) revert InvalidRecipient();
            uint32 alloc = percentAllocations[i];
            if (alloc == 0) revert AllocationMustBePositive();
            if (uint256(alloc) > PERCENTAGE_SCALE) revert InvalidAllocationsSum();
            sum += alloc;

            // Check for duplicates
            unchecked {
                for (uint256 j = i + 1; j < accounts.length; ++j) {
                    if (accounts[i] == accounts[j]) revert DuplicateAccount();
                }
            }
        }

        if (sum != PERCENTAGE_SCALE) revert InvalidAllocationsSum();
    }

    function _distributeETH(uint256 amountToSplit, address[] calldata accounts, uint32[] calldata percentAllocations)
        internal
    {
        uint256[] memory shares = _calculateShares(address(0), amountToSplit, accounts, percentAllocations);
        for (uint256 i; i < accounts.length; ++i) {
            if (shares[i] != 0) SafeTransferLib.safeTransferETH(accounts[i], shares[i]);
        }
    }

    function _distributeERC20(
        address token,
        uint256 amountToSplit,
        address[] calldata accounts,
        uint32[] calldata percentAllocations
    ) internal {
        uint256[] memory shares = _calculateShares(token, amountToSplit, accounts, percentAllocations);
        for (uint256 i; i < accounts.length; ++i) {
            if (shares[i] != 0) SafeTransferLib.safeTransfer(token, accounts[i], shares[i]);
        }
    }

    function _calculateShares(
        address asset,
        uint256 currentBalance,
        address[] calldata accounts,
        uint32[] calldata percentAllocations
    ) internal returns (uint256[] memory shares) {
        uint256 version = _splitVersion;
        uint256 retained = _retainedAmount[version][asset];
        shares = new uint256[](accounts.length);

        // A negative-rebasing token can make previously retained dust disappear.
        // Reset the affected asset's fractional state and apportion any surviving
        // balance from a clean baseline instead of charging the loss to a later deposit.
        if (currentBalance < retained) {
            for (uint256 i; i < accounts.length; ++i) {
                _fractionalCarry[version][asset][accounts[i]] = 0;
            }
            retained = 0;
        }

        uint256 newAmount = currentBalance - retained;
        uint256 distributed;
        for (uint256 i; i < accounts.length; ++i) {
            uint256 share = _calculateShare(version, asset, accounts[i], newAmount, percentAllocations[i]);
            shares[i] = share;
            distributed += share;
        }

        _retainedAmount[version][asset] = currentBalance - distributed;
    }

    function _calculateShare(uint256 version, address asset, address account, uint256 amount, uint256 allocation)
        internal
        returns (uint256 share)
    {
        share = _scaleAmountByPercentage(amount, allocation);
        uint256 carry = _fractionalCarry[version][asset][account] + mulmod(amount, allocation, PERCENTAGE_SCALE);
        if (carry >= PERCENTAGE_SCALE) {
            ++share;
            carry -= PERCENTAGE_SCALE;
        }
        _fractionalCarry[version][asset][account] = carry;
    }

    function _scaleAmountByPercentage(uint256 amount, uint256 scaledPercent)
        internal
        pure
        returns (uint256 scaledAmount)
    {
        scaledAmount = FixedPointMathLib.fullMulDiv(amount, scaledPercent, PERCENTAGE_SCALE);
    }
}
