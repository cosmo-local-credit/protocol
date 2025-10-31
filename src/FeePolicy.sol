// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IFeePolicy} from "./interfaces/IFeePolicy.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract FeePolicy is IFeePolicy, Ownable, Initializable {
    error InvalidFee();
    error InvalidToken();

    uint256 public constant PPM = 1_000_000;

    uint256 public defaultFee;

    // keccak256(abi.encodePacked(tokenIn, tokenOut)) => fee
    mapping(bytes32 => uint256) private pairFees;

    event DefaultFeeUpdated(uint256 oldFee, uint256 newFee);

    event PairFeeUpdated(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 oldFee,
        uint256 newFee
    );

    event PairFeeRemoved(address indexed tokenIn, address indexed tokenOut);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        uint256 defaultFee_
    ) external initializer {
        _initializeOwner(owner_);
        if (defaultFee_ > PPM) revert InvalidFee();
        defaultFee = defaultFee_;
        emit DefaultFeeUpdated(0, defaultFee_);
    }

    function getFee(
        address tokenIn,
        address tokenOut
    ) external view override returns (uint256) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        uint256 pairFee = pairFees[pairKey];

        return pairFee != 0 ? pairFee : defaultFee;
    }

    function isActive() external pure override returns (bool) {
        return true;
    }

    function getDefaultFee() external view returns (uint256) {
        return defaultFee;
    }

    function setDefaultFee(uint256 newDefaultFee_) external onlyOwner {
        if (newDefaultFee_ > PPM) revert InvalidFee();

        uint256 oldFee = defaultFee;
        defaultFee = newDefaultFee_;

        emit DefaultFeeUpdated(oldFee, newDefaultFee_);
    }

    function setPairFee(
        address tokenIn,
        address tokenOut,
        uint256 fee_
    ) external onlyOwner {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert InvalidToken();
        }
        if (fee_ > PPM) revert InvalidFee();

        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        uint256 oldFee = pairFees[pairKey];
        if (oldFee == 0) {
            oldFee = defaultFee;
        }

        pairFees[pairKey] = fee_;

        emit PairFeeUpdated(tokenIn, tokenOut, oldFee, fee_);
    }

    function removePairFee(
        address tokenIn,
        address tokenOut
    ) external onlyOwner {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));

        if (pairFees[pairKey] != 0) {
            delete pairFees[pairKey];
            emit PairFeeRemoved(tokenIn, tokenOut);
        }
    }

    function calculateFee(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external view returns (uint256) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        uint256 feePpm = pairFees[pairKey];

        if (feePpm == 0) {
            feePpm = defaultFee;
        }

        return (amount * feePpm) / PPM;
    }
}
