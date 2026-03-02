// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface ICAT {
    function setTokens(address[] calldata tokens) external;
    function getTokens(address account) external view returns (address[] memory);
    function tokenAt(address account, uint256 index) external view returns (address);
    function tokenCount(address account) external view returns (uint256);
}
