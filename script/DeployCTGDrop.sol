// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {CTGPlayerNFT} from "../src/CTGPlayerNFT.sol";
import {CTGPlayerNFTProxy} from "../src/CTGPlayerNFTProxy.sol";
import {DropMetadataRenderer} from "../src/metadata/DropMetadataRenderer.sol";
import {TransferPauserExtension} from "../src/extensions/TransferPauserExtension.sol";

contract Deploy is Script {
    function run() public {
        address sender = vm.envAddress("SENDER");
        vm.startBroadcast(sender);

        address impl = address(new CTGPlayerNFT());

        /**
        
            string memory _contractName,
            string memory _contractSymbol,
            address _initialOwner,
            address payable _fundsRecipient,
            uint64 _editionSize,
            uint16 _royaltyBPS,
            bytes[] calldata _setupCalls,
            IMetadataRenderer _metadataRenderer,
            bytes memory _metadataRendererInit
        
         */

        if (block.chainid != 84532) {
            revert("Only support base testnet");
        }

        // TODO change to real address
        address initialOwner;
        address dropRenderer;
        
        if (block.chainid == 84532) {
            initialOwner = address(sender);
            dropRenderer = address(0xf643704CfB538aF53Dea5DFE9B1e795b9abf3bBf);
        } else if (block.chainid == 8453) {
            // todo change
            initialOwner = address(sender);
            dropRenderer = address(0xd1cba36d92B052079523F471Eb891563F2E5dF5C);
        } else {
            revert("Unsupported chain");
        }

        // total edition size of drop
        uint256 editionSize = 700;

        bytes[] memory setupCalls = new bytes[](0);

        bytes memory metadataRendererInit = abi.encode(
            "https://www.721.so/api/example/metadata/", // initial base uri,
            "https://www.721.so/api/example/metadata/1" // initial contract uri
        );

        address proxy = address(
            new CTGPlayerNFTProxy(
                impl,
                abi.encodeWithSelector(
                    CTGPlayerNFT.initialize.selector,
                    "CTGPlayerDemo Season 2", // contractName
                    "CTGPS2", // contractSymbol
                    initialOwner,
                    initialOwner,
                    editionSize,
                    1000, // 10%
                    setupCalls,
                    dropRenderer,
                    metadataRendererInit
                )
            )
        );

        TransferPauserExtension transferPauserExtension = new TransferPauserExtension(proxy);
        // CTGPlayerNFTImpl(proxy).setTransferHook(transferPauserExtension);
        console2.log("Transfer pauser extension deployed to: ", address(transferPauserExtension));

        console2.log("Deployed to: ", proxy);
    }
}
