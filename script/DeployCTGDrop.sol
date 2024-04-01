// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {CTGPlayerNFT} from "../src/CTGPlayerNFT.sol";
import {CTGPlayerNFTProxy} from "../src/CTGPlayerNFTProxy.sol";
import {DropMetadataRenderer} from "../src/metadata/DropMetadataRenderer.sol";
import {TransferPauserExtension} from "../src/extensions/TransferPauserExtension.sol";
import {PermissionedDeployer, DeploymentSettings} from "../src/deploy/PermissionedDeployer.sol";

contract Deploy is Script {
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant BASE_MAINNET = 8453;

    function getConfigForChain() internal view returns (DeploymentSettings memory) {
        if (block.chainid == BASE_SEPOLIA) {
            return
                DeploymentSettings({
                    deployer: address(0x07966725a7928083bA85e75276518561D0c28B19),
                    initialOwner: address(0x07966725a7928083bA85e75276518561D0c28B19),
                    fundsRecipient: address(0x07966725a7928083bA85e75276518561D0c28B19),
                    royaltyRecipient: address(0x07966725a7928083bA85e75276518561D0c28B19),
                    contractName: string("CTGS2TEST"),
                    contractSymbol: string("CTGS2TEST"),
                    royaltyBPS: 1500,
                    editionSize: 800,
                    dropRenderer: address(0xf643704CfB538aF53Dea5DFE9B1e795b9abf3bBf),
                    metadataRendererInit: abi.encode(
                        "https://www.721.so/api/example/metadata/", // initial base uri,
                        "https://www.721.so/api/example/metadata/1" // initial contract uri
                    )
                });
        }
        if (block.chainid == BASE_MAINNET) {
            return
                DeploymentSettings({
                    deployer: address(0xbf52f76E016C87cBC321E1688C762F53B4d2Ae0b /* iain dev */),
                    initialOwner: address(0x78E4318F5B7B4eea01646Cbb37Ac048Cd4cEdd36),
                    fundsRecipient: address(0x8A8F49eF12333C1eF957DA17927A8427D38d67Fb),
                    royaltyRecipient: address(0x78E4318F5B7B4eea01646Cbb37Ac048Cd4cEdd36),
                    contractName: string("CTTTG2"),
                    contractSymbol: string("CTTTG2"),
                    royaltyBPS: 1500,
                    editionSize: 800,
                    dropRenderer: address(0xd1cba36d92B052079523F471Eb891563F2E5dF5C),
                    metadataRendererInit: abi.encode(
                        "https://www.721.so/api/example/metadata/", // initial base uri,
                        "https://www.721.so/api/example/metadata/1" // initial contract uri
                    )
                });
        }
        revert("chain is not configured");
    }

    function run() public {
        address sender = vm.envAddress("SENDER");
        vm.startBroadcast(sender);

        address impl = address(new CTGPlayerNFT());

        DeploymentSettings memory deploymentSettings = getConfigForChain();

        PermissionedDeployer permissionedDeployer = new PermissionedDeployer(deploymentSettings, impl);

        console2.log("Deployed Permissioned Deployer to: ", address(permissionedDeployer));
        if (deploymentSettings.deployer == sender) {
            permissionedDeployer.deploy();
        }
    }
}
