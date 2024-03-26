// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransferPauserExtension} from "../../src/extensions/TransferPauserExtension.sol";

contract BaseContractMock {

    mapping(bytes32 => mapping(address => bool)) hasRoleStorage;
    function hasRole(bytes32 role, address user) external view returns (bool) {
        return hasRoleStorage[role][user];
    }

    function setRole(bytes32 role, address user) public {
        hasRoleStorage[role][user] = true;
    }


}

contract TransferPauserExtensionTest is Test {
    BaseContractMock baseContractMock;
    TransferPauserExtension transferPauserExtension;
    
    function setUp() public {
        baseContractMock = new BaseContractMock();
        transferPauserExtension = new TransferPauserExtension(address(baseContractMock)); 
    }

    function testAccessControl() public {
        address sender = address(0x1234);
        uint256[] memory players = new uint256[](2);
        players[0] = 1;
        players[1] = 4;
        vm.startPrank(sender);
        vm.expectRevert(TransferPauserExtension.GameControllerRoleNeeded.selector);
        transferPauserExtension.setPlayersEliminated(players);
    }

    function testBeforeTokenTransferFails() public {
        address sender = address(0x1234);
        uint256[] memory players = new uint256[](2);
        players[0] = 1;
        players[1] = 4;
        vm.startPrank(sender);
        baseContractMock.setRole(transferPauserExtension.GAME_CONTROLLER_ROLE(), sender);
        transferPauserExtension.setPlayersEliminated(players);
        vm.expectRevert(abi.encodeWithSelector(TransferPauserExtension.JuryNFTsCannotBeTransferred.selector, 1));
        transferPauserExtension.beforeTokenTransfers(address(0), address(0), address(0), 1, 5);
        vm.expectRevert(abi.encodeWithSelector(TransferPauserExtension.JuryNFTsCannotBeTransferred.selector, 4));
        transferPauserExtension.beforeTokenTransfers(address(0), address(0), address(0), 2, 5);
    }
}