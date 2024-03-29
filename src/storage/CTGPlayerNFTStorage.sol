// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ICTGPlayerNFT} from "../interfaces/ICTGPlayerNFT.sol";

struct CTGPlayerNFTStorage {
    /// @notice Configuration for NFT minting contract storage
    ICTGPlayerNFT.Configuration config;

    /// @notice Sales configuration
    ICTGPlayerNFT.SalesConfiguration salesConfig;

    /// @notice Extension for transfer hook across the whole contract. Optional – disabled if set to address(0).
    address transferHookExtension;

    address royaltyRecipient;
}

contract CTGPlayerNFTStorageBase {
    // keccak256(abi.encode(uint256(keccak256("ctg.playernft.nft")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CTG_PLAYER_NFT_STORAGE_LOCATION = 0x34fb9baf3ba6f67af827ec42cb40e69ca8bdb2828c5785454de507ce349be500;

    /// @notice Function to get the current transfer hook storage from its direct storage slot.
    function _getCTGPlayerNFTStorage() internal pure returns (CTGPlayerNFTStorage storage $) {
        assembly {
            $.slot := CTG_PLAYER_NFT_STORAGE_LOCATION 
        }
    }

}
