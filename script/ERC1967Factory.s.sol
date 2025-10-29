// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "solady/utils/ERC1967Factory.sol";

contract DeployERC1967FactoryScript {
    function run() external returns (ERC1967Factory factory) {
        factory = new ERC1967Factory();
    }
}
