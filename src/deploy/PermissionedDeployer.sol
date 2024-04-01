// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ICTGPlayerNFT} from "../interfaces/ICTGPlayerNFT.sol";
import {CTGPlayerNFT} from "../CTGPlayerNFT.sol";
import {TransferPauserExtension} from "../extensions/TransferPauserExtension.sol";
import {CTGPlayerNFTProxy} from "../CTGPlayerNFTProxy.sol";

struct DeploymentSettings {
    address deployer;
    address initialOwner;
    address fundsRecipient;
    address royaltyRecipient;
    string contractName;
    string contractSymbol;
    uint16 royaltyBPS;
    uint256 editionSize;
    address dropRenderer;
    bytes metadataRendererInit;
}

contract PermissionedDeployer {
    bool public deployed;

    DeploymentSettings public deploymentSettings;
    address public ctgPlayerNFTImpl;

    event DeployedExtensionAndProxy(address proxy, address extension);

    constructor(DeploymentSettings memory deploymentSettings_, address ctgPlayerNFTImpl_) {
        deploymentSettings = deploymentSettings_;
        ctgPlayerNFTImpl = ctgPlayerNFTImpl_;

        if (ctgPlayerNFTImpl == address(0)) {
            revert("Not a valid addr");
        }
    }

    function deploy() external returns (address proxy, address transferPauserExtension) {
        if (deploymentSettings.deployer != msg.sender) {
            revert("msg.sender is not the deployer");
        }

        if (deployed) {
            revert("already deployed");
        }

        deployed = true;

        bytes[] memory setupCalls = new bytes[](0);
        proxy = address(
            new CTGPlayerNFTProxy(
                ctgPlayerNFTImpl,
                abi.encodeWithSelector(
                    CTGPlayerNFT.initialize.selector,
                    deploymentSettings.contractName, // contractName
                    deploymentSettings.contractSymbol, // contractSymbol
                    deploymentSettings.initialOwner, // initial owner
                    deploymentSettings.fundsRecipient, // funds recipient
                    deploymentSettings.editionSize,
                    deploymentSettings.royaltyRecipient, // royalty recipient
                    deploymentSettings.royaltyBPS, // royalty BPS
                    setupCalls,
                    deploymentSettings.dropRenderer,
                    deploymentSettings.metadataRendererInit
                )
            )
        );
        transferPauserExtension = address(new TransferPauserExtension(proxy));
        emit DeployedExtensionAndProxy(proxy, address(transferPauserExtension));
    }
}
