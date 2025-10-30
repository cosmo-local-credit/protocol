// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "solady/utils/ERC1967Factory.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployERC1967FactoryScript is Script {
    ERC1967Factory public factory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        factory = new ERC1967Factory();
        vm.stopBroadcast();
    }
}
