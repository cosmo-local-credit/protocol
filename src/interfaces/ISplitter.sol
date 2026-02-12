// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ISplitter {
    function initialize(address owner, address[] calldata accounts, uint32[] calldata percentAllocations) external;

    function updateSplit(address[] calldata accounts, uint32[] calldata percentAllocations) external;

    function distributeETH(address[] calldata accounts, uint32[] calldata percentAllocations) external;

    function distributeERC20(address token, address[] calldata accounts, uint32[] calldata percentAllocations) external;

    function getHash() external view returns (bytes32);
}
