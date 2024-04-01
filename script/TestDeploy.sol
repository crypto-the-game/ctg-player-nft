// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {CTGPlayerNFT} from "../src/CTGPlayerNFT.sol";
import {CTGPlayerNFTProxy} from "../src/CTGPlayerNFTProxy.sol";
import {DropMetadataRenderer} from "../src/metadata/DropMetadataRenderer.sol";
import {TransferPauserExtension} from "../src/extensions/TransferPauserExtension.sol";
import {PermissionedDeployer, DeploymentSettings} from "../src/deploy/PermissionedDeployer.sol";

contract TestDeploy is Script {
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant BASE_MAINNET = 8453;

    function run() public {
        address sender = vm.envAddress("SENDER");
        vm.startBroadcast(sender);

        PermissionedDeployer permissionedDeployer = PermissionedDeployer(address(0xa80f737cC5BFdD1f1bD0e968F7deD6b624eA8935));

        permissionedDeployer.deploy();
    }
}
