// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IEthFaucet {
    function giveTo(address _recipient) external returns (uint256);
}
