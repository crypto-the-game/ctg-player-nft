// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ITransferHookExtension} from "../interfaces/ITransferHookExtension.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";


contract TransferPauserExtension is ITransferHookExtension, ERC165 {
    bytes32 immutable public GAME_CONTROLLER_ROLE = keccak256("GAME_CONTROLLER_ROLE");
    IAccessControl public immutable baseNFT;

    error GameControllerRoleNeeded();
    error JuryNFTsCannotBeTransferred(uint256 tokenId);
    event PlayersSetEliminatedAt(address indexed by, uint256[] indexed players, uint256 timestamp);

    mapping(uint256 => uint256) playerBecameJuryAt;

    constructor(address baseNFT_) {
        baseNFT = IAccessControl(baseNFT_);
    }

    function playersBecameJuryAt(uint256[] memory playerIds) external view returns (uint256[] memory playersResult) {
        playersResult = new uint256[](playerIds.length);
        for (uint256 i = 0; i < playerIds.length; i++) {
            playersResult[i] = playerBecameJuryAt[playerIds[i]];
        }
    }

    function singlePlayerBecameJuryAt(uint256 playerId) external view returns (uint256) {
        return playerBecameJuryAt[playerId];
    }

    function _requireGameControllerRole() internal view {
        if (!baseNFT.hasRole(GAME_CONTROLLER_ROLE, msg.sender)) {
            revert GameControllerRoleNeeded();
        }
    }

    function setPlayersEliminated(uint256[] memory players) external {
        _requireGameControllerRole();
        emit PlayersSetEliminatedAt(msg.sender, players, block.timestamp);
        for (uint256 i = 0; i < players.length; i++) {
            playerBecameJuryAt[players[i]] = block.timestamp;
        }
    }

    function revokePlayersEliminated(uint256[] memory players) external {
        _requireGameControllerRole();
        emit PlayersSetEliminatedAt(msg.sender, players, 0);
        for (uint256 i = 0; i < players.length; i++) {
            playerBecameJuryAt[players[i]] = 0;
        }
    }

    function canTransfer(uint256 tokenId) public view returns (bool) {
        if (playerBecameJuryAt[tokenId] == 0) {
            return true;
        }
        return false;
    }

    function _requireCanTransfer(uint256 tokenId) internal view {
        if (!canTransfer(tokenId)) {
            revert JuryNFTsCannotBeTransferred(tokenId);
        }
    }

    function beforeTokenTransfers(address /* from */, address /* to */, address /* operator */, uint256 startTokenId, uint256 quantity) external view {
        for (uint256 i = startTokenId; i < startTokenId + quantity; i++) {
            _requireCanTransfer(i);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, ITransferHookExtension) returns (bool) {
        return (interfaceId == type(ITransferHookExtension).interfaceId || super.supportsInterface(interfaceId));
    }
}
