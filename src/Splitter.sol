// Author: Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	0xSplits
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISplitter} from "./interfaces/ISplitter.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract Splitter is ISplitter, Ownable, Initializable {
    uint256 public constant PERCENTAGE_SCALE = 1_000_000;

    error TooFewAccounts();
    error AccountsAndAllocationsMismatch();
    error InvalidAllocationsSum();
    error DuplicateAccount();
    error AllocationMustBePositive();
    error InvalidHash();

    bytes32 internal _splitHash;

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address owner, address[] calldata accounts, uint32[] calldata percentAllocations)
        external
        initializer
    {
        _initializeOwner(owner);
        _validateSplit(accounts, percentAllocations);
        _splitHash = _hashSplit(accounts, percentAllocations);
    }

    function updateSplit(address[] calldata accounts, uint32[] calldata percentAllocations) external onlyOwner {
        _validateSplit(accounts, percentAllocations);
        _splitHash = _hashSplit(accounts, percentAllocations);
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
        if (grossAmount == 0) return;

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

    function _validateSplit(address[] calldata accounts, uint32[] calldata percentAllocations) internal pure {
        if (accounts.length < 2) revert TooFewAccounts();
        if (accounts.length != percentAllocations.length) revert AccountsAndAllocationsMismatch();

        uint32 sum;
        unchecked {
            for (uint256 i; i < accounts.length; ++i) {
                uint32 alloc = percentAllocations[i];
                if (alloc == 0) revert AllocationMustBePositive();
                sum += alloc;

                // Check for duplicates
                for (uint256 j = i + 1; j < accounts.length; ++j) {
                    if (accounts[i] == accounts[j]) revert DuplicateAccount();
                }
            }
        }

        if (sum != uint32(PERCENTAGE_SCALE)) revert InvalidAllocationsSum();
    }

    function _distributeETH(uint256 amountToSplit, address[] calldata accounts, uint32[] calldata percentAllocations)
        internal
    {
        uint256 running;
        uint256 last = accounts.length - 1;
        unchecked {
            for (uint256 i; i < last; ++i) {
                uint256 share = _scaleAmountByPercentage(amountToSplit, percentAllocations[i]);
                running += share;
                if (share != 0) SafeTransferLib.safeTransferETH(accounts[i], share);
            }
        }
        uint256 remainder = amountToSplit - running;
        if (remainder != 0) SafeTransferLib.safeTransferETH(accounts[last], remainder);
    }

    function _distributeERC20(
        address token,
        uint256 amountToSplit,
        address[] calldata accounts,
        uint32[] calldata percentAllocations
    ) internal {
        uint256 running;
        uint256 last = accounts.length - 1;
        unchecked {
            for (uint256 i; i < last; ++i) {
                uint256 share = _scaleAmountByPercentage(amountToSplit, percentAllocations[i]);
                running += share;
                if (share != 0) SafeTransferLib.safeTransfer(token, accounts[i], share);
            }
        }
        uint256 remainder = amountToSplit - running;
        if (remainder != 0) SafeTransferLib.safeTransfer(token, accounts[last], remainder);
    }

    function _scaleAmountByPercentage(uint256 amount, uint256 scaledPercent)
        internal
        pure
        returns (uint256 scaledAmount)
    {
        assembly {
            scaledAmount := div(mul(amount, scaledPercent), PERCENTAGE_SCALE)
        }
    }
}
