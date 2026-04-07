// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IAccountsIndex {
    function add(address _account) external returns (bool);
}
