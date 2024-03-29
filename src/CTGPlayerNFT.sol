// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**

    _____ _____ _____    _____                        ___ 
    |     |_   _|   __|  |   __|___ ___ ___ ___ ___   |_  |
    |   --| | | |  |  |  |__   | -_| .'|_ -| . |   |  |  _|
    |_____| |_| |_____|  |_____|___|__,|___|___|_|_|  |___|
                                                        
                                                        
    _____ _                    _____ _____ _____          
    |  _  | |___ _ _ ___ ___   |   | |   __|_   _|         
    |   __| | .'| | | -_|  _|  | | | |   __| | |           
    |__|  |_|__,|_  |___|_|    |_|___|__|    |_|           
                |___|                                      

 */

import {ERC721AUpgradeable} from "erc721a-upgradeable/ERC721AUpgradeable.sol";
import {ERC721AStorage} from "erc721a-upgradeable/ERC721AStorage.sol";
import {IERC721AUpgradeable} from "erc721a-upgradeable/IERC721AUpgradeable.sol";
import {IERC2981, IERC165} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ITransferHookExtension} from "./interfaces/ITransferHookExtension.sol";
import {IMetadataRenderer} from "./interfaces/IMetadataRenderer.sol";
import {ICTGPlayerNFT} from "./interfaces/ICTGPlayerNFT.sol";
import {IOwnable} from "./interfaces/IOwnable.sol";
import {IERC4906} from "./interfaces/IERC4906.sol";
import {IFactoryUpgradeGate} from "./interfaces/IFactoryUpgradeGate.sol";
import {OwnableSkeleton} from "./utils/OwnableSkeleton.sol";
import {FundsReceiver} from "./utils/FundsReceiver.sol";
import {Version} from "./utils/Version.sol";
import {PublicMulticall} from "./utils/PublicMulticall.sol";
import {CTGPlayerNFTStorageBase, CTGPlayerNFTStorage} from "./storage/CTGPlayerNFTStorage.sol";

/**
 * @dev For drops: assumes 1. linear mint order, 2. max number of mints needs to be less than max_uint64
 *       (if you have more than 18 quintillion linear mints you should probably not be using this contract)
 * @notice Forked from ZORA drops for additional features
 */
contract CTGPlayerNFT is
    ERC721AUpgradeable,
    UUPSUpgradeable,
    IERC2981,
    IERC4906,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    ICTGPlayerNFT,
    PublicMulticall,
    OwnableSkeleton,
    FundsReceiver,
    Version(0x002),
    CTGPlayerNFTStorageBase
{
    /// @dev This is the max mint batch size for the optimized ERC721A mint contract
    uint256 internal immutable MAX_MINT_BATCH_SIZE = 8;

    /// @dev Gas limit to send funds
    uint256 internal immutable FUNDS_SEND_GAS_LIMIT = 210_000;

    /// @notice Access control roles
    bytes32 public immutable MINTER_ROLE = keccak256("MINTER");
    bytes32 public immutable SALES_MANAGER_ROLE = keccak256("SALES_MANAGER");
    bytes32 public immutable UPGRADER_ROLE = keccak256("UPGRADER");

    /// @notice Max royalty BPS
    uint16 constant MAX_ROYALTY_BPS = 50_00;

    // /// @notice Empty string for blank comments
    // string constant EMPTY_STRING = "";

    /// @notice Only allow for users with admin access
    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert Access_OnlyAdmin();
        }

        _;
    }

    /// @notice Only a given role has access or admin
    /// @param role role to check for alongside the admin role
    modifier onlyRoleOrAdmin(bytes32 role) {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(role, _msgSender())) {
            revert Access_MissingRoleOrAdmin(role);
        }

        _;
    }

    /// @notice Allows user to mint tokens at a quantity
    modifier canMintTokens(uint256 quantity) {
        if (quantity + _totalMinted() > _getCTGPlayerNFTStorage().config.editionSize) {
            revert Mint_SoldOut();
        }

        _;
    }

    function _presaleActive() internal view returns (bool) {
        ICTGPlayerNFT.SalesConfiguration storage salesConfigLocal = _getCTGPlayerNFTStorage().salesConfig;
        return salesConfigLocal.presaleStart <= block.timestamp && salesConfigLocal.presaleEnd > block.timestamp;
    }

    function _publicSaleActive() internal view returns (bool) {
        ICTGPlayerNFT.SalesConfiguration storage salesConfigLocal = _getCTGPlayerNFTStorage().salesConfig;
        return salesConfigLocal.publicSaleStart <= block.timestamp && salesConfigLocal.publicSaleEnd > block.timestamp;
    }

    /// @notice Presale active
    modifier onlyPresaleActive() {
        if (!_presaleActive()) {
            revert Presale_Inactive();
        }

        _;
    }

    /// @notice Public sale active
    modifier onlyPublicSaleActive() {
        if (!_publicSaleActive()) {
            revert Sale_Inactive();
        }

        _;
    }

    /// @notice Getter for last minted token ID (gets next token id and subtracts 1)
    function _lastMintedTokenId() internal view returns (uint256) {
        return ERC721AStorage.layout()._currentIndex - 1;
    }

    /// @notice Start token ID for minting (1-100 vs 0-99)
    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    /// @notice Global constructor – these variables will not change with further proxy deploys
    /// @dev Marked as an initializer to prevent storage being used of base implementation. Can only be init'd by a proxy.
    constructor() initializer initializerERC721A {}

    ///  @dev Create a new drop contract
    ///  @param _contractName Contract name
    ///  @param _contractSymbol Contract symbol
    ///  @param _initialOwner User that owns and can mint the edition, gets royalty and sales payouts and can update the base url if needed.
    ///  @param _fundsRecipient Wallet/user that receives funds from sale
    ///  @param _editionSize Number of editions that can be minted in total. If type(uint64).max, unlimited editions can be minted as an open edition.
    ///  @param _royaltyBPS BPS of the royalty set on the contract. Can be 0 for no royalty.
    ///  @param _setupCalls Bytes-encoded list of setup multicalls
    ///  @param _metadataRenderer Renderer contract to use
    ///  @param _metadataRendererInit Renderer data initial contract
    function initialize(
        string memory _contractName,
        string memory _contractSymbol,
        address _initialOwner,
        address payable _fundsRecipient,
        uint64 _editionSize,
        uint16 _royaltyBPS,
        bytes[] calldata _setupCalls,
        IMetadataRenderer _metadataRenderer,
        bytes memory _metadataRendererInit
    ) public initializer initializerERC721A {
        // Setup ERC721A
        __ERC721A_init(_contractName, _contractSymbol);
        // Setup access control
        __AccessControl_init();
        // Setup re-entracy guard
        __ReentrancyGuard_init();
        // Setup the owner role
        _grantRole(DEFAULT_ADMIN_ROLE, _initialOwner);
        // Set ownership to original sender of contract call
        _setOwner(_initialOwner);

        if (_setupCalls.length > 0) {
            // Setup temporary role
            _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
            // Execute setupCalls
            multicall(_setupCalls);
            // Remove temporary role
            _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }

        ICTGPlayerNFT.Configuration storage nftConfig = _getCTGPlayerNFTStorage().config;

        // Setup nftConfig variables
        nftConfig.editionSize = _editionSize;
        nftConfig.metadataRenderer = _metadataRenderer;
        nftConfig.fundsRecipient = _fundsRecipient;
        _updateRoyaltySettings(_royaltyBPS);

        _metadataRenderer.initializeWithData(_metadataRendererInit);
    }

    /// @dev Getter for admin role associated with the contract to handle metadata
    /// @return boolean if address is admin
    function isAdmin(address user) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, user);
    }

    /// @notice Connects this contract to the factory upgrade gate
    /// @param newImplementation proposed new upgrade implementation
    /// @dev Only can be called by admin
    function _authorizeUpgrade(address newImplementation) internal override {
        if (!hasRole(UPGRADER_ROLE, msg.sender)) {
            revert NotAllowedToUpgrade();
        }

        if (!Strings.equal(ICTGPlayerNFT(newImplementation).contractName(), contractName())) {
            revert ContractIdentityWrong();
        }
    }

    function config() external view returns (IMetadataRenderer renderer, uint64 editionSize, uint16 royaltyBPS, address payable fundsRecipient) {
        ICTGPlayerNFT.Configuration memory internalConfig = _getCTGPlayerNFTStorage().config;

        renderer = internalConfig.metadataRenderer;
        editionSize = internalConfig.editionSize;
        royaltyBPS = internalConfig.royaltyBPS;
        fundsRecipient = internalConfig.fundsRecipient;
    }

    function salesConfig()
        external
        view
        returns (
            uint104 publicSalePrice,
            uint32 maxSalePurchasePerAddress,
            uint64 publicSaleStart,
            uint64 publicSaleEnd,
            uint64 presaleStart,
            uint64 presaleEnd,
            bytes32 presaleMerkleRoot
        )
    {
        ICTGPlayerNFT.SalesConfiguration storage salesConfigurationInternal = _getCTGPlayerNFTStorage().salesConfig;

        publicSalePrice = salesConfigurationInternal.publicSalePrice;
        maxSalePurchasePerAddress = salesConfigurationInternal.maxSalePurchasePerAddress;
        publicSaleStart = salesConfigurationInternal.publicSaleStart;
        publicSaleEnd = salesConfigurationInternal.publicSaleEnd;
        presaleStart = salesConfigurationInternal.presaleStart;
        presaleEnd = salesConfigurationInternal.presaleEnd;
        presaleMerkleRoot = salesConfigurationInternal.presaleMerkleRoot;
    }

    function contractName() public pure returns (string memory) {
        return "CTGPlayerNFT";
    }

    /// @notice Admin function to set the NFT transfer hook, useful for metadata and non-transferrable NFTs.
    /// @dev Set to 0 to disable, address to enable transfer hook.
    /// @param newTransferHook new transfer hook to receive before token transfer events
    function setTransferHook(address newTransferHook) public onlyAdmin {
        if (newTransferHook != address(0) && !ITransferHookExtension(newTransferHook).supportsInterface(type(ITransferHookExtension).interfaceId)) {
            revert InvalidTransferHook();
        }

        emit SetNewTransferHook(newTransferHook);
        _getCTGPlayerNFTStorage().transferHookExtension = newTransferHook;
    }

    /// @notice Handles the internal before token transfer hook
    /// @param from address transfer is coming from
    /// @param to address transfer is going to
    /// @param startTokenId token id for transfer
    /// @param quantity number of transfers
    function _beforeTokenTransfers(address from, address to, uint256 startTokenId, uint256 quantity) internal virtual override {
        address transferHookExtension = _getCTGPlayerNFTStorage().transferHookExtension;
        if (transferHookExtension != address(0)) {
            ITransferHookExtension(transferHookExtension).beforeTokenTransfers({
                from: from,
                to: to,
                operator: msg.sender,
                startTokenId: startTokenId,
                quantity: quantity
            });
        }

        super._beforeTokenTransfers(from, to, startTokenId, quantity);
    }

    //        ,-.
    //        `-'
    //        /|\
    //         |             ,----------.
    //        / \            |CTGPlayerNFT|
    //      Caller           `----+-----'
    //        |       burn()      |
    //        | ------------------>
    //        |                   |
    //        |                   |----.
    //        |                   |    | burn token
    //        |                   |<---'
    //      Caller           ,----+-----.
    //        ,-.            |CTGPlayerNFT|
    //        `-'            `----------'
    //        /|\
    //         |
    //        / \
    /// @param tokenId Token ID to burn
    /// @notice User burn function for token id
    function burn(uint256 tokenId) public {
        _burn(tokenId, true);
    }

    /// @dev Get royalty information for token
    /// @param _salePrice Sale price for the token
    function royaltyInfo(uint256, uint256 _salePrice) external view override returns (address receiver, uint256 royaltyAmount) {
        ICTGPlayerNFT.Configuration storage nftConfig = _getCTGPlayerNFTStorage().config;
        if (nftConfig.fundsRecipient == address(0)) {
            return (nftConfig.fundsRecipient, 0);
        }
        return (nftConfig.fundsRecipient, (_salePrice * nftConfig.royaltyBPS) / 10_000);
    }

    /// @notice Sale details
    /// @return ICTGPlayerNFT.SaleDetails sale information details
    function saleDetails() external view returns (ICTGPlayerNFT.SaleDetails memory) {
        CTGPlayerNFTStorage storage nftStorage = _getCTGPlayerNFTStorage();
        return
            ICTGPlayerNFT.SaleDetails({
                publicSaleActive: _publicSaleActive(),
                presaleActive: _presaleActive(),
                publicSalePrice: nftStorage.salesConfig.publicSalePrice,
                publicSaleStart: nftStorage.salesConfig.publicSaleStart,
                publicSaleEnd: nftStorage.salesConfig.publicSaleEnd,
                presaleStart: nftStorage.salesConfig.presaleStart,
                presaleEnd: nftStorage.salesConfig.presaleEnd,
                presaleMerkleRoot: nftStorage.salesConfig.presaleMerkleRoot,
                totalMinted: _totalMinted(),
                maxSupply: nftStorage.config.editionSize,
                maxSalePurchasePerAddress: nftStorage.salesConfig.maxSalePurchasePerAddress
            });
    }

    /// @dev Number of NFTs the user has minted per address
    /// @param minter to get counts for
    function mintedPerAddress(address minter) external view override returns (ICTGPlayerNFT.AddressMintDetails memory) {
        return
            ICTGPlayerNFT.AddressMintDetails({
                // Presale mints are disabled on this version of the contract
                presaleMints: 0,
                publicMints: _numberMinted(minter),
                totalMints: _numberMinted(minter)
            });
    }

    /// @notice ZORA fee is fixed now per mint
    /// @dev Gets the zora fee for amount of withdraw
    function zoraFeeForAmount(uint256 /* quantity */) public pure returns (address payable recipient, uint256 fee) {
        recipient = payable(address(0));
        fee = 0;
    }

    /**
     *** ---------------------------------- ***
     ***                                    ***
     ***     PUBLIC MINTING FUNCTIONS       ***
     ***                                    ***
     *** ---------------------------------- ***
     ***/

    /**
      @dev This allows the user to purchase a edition edition
           at the given price in the contract.
     */
    /// @notice Purchase a quantity of tokens
    /// @param quantity quantity to purchase
    /// @return tokenId of the first token minted
    function purchase(uint256 quantity) external payable nonReentrant onlyPublicSaleActive returns (uint256) {
        return _handleMint(msg.sender, quantity, "");
    }

    /// @notice Purchase a quantity of tokens with a comment
    /// @param quantity quantity to purchase
    /// @param comment comment to include in the ICTGPlayerNFT.Sale event
    /// @return tokenId of the first token minted
    function purchaseWithComment(uint256 quantity, string calldata comment) external payable nonReentrant onlyPublicSaleActive returns (uint256) {
        return _handleMint(msg.sender, quantity, comment);
    }

    /// @notice Purchase a quantity of tokens to a specified recipient, with an optional comment
    /// @param recipient recipient of the tokens
    /// @param quantity quantity to purchase
    /// @param comment optional comment to include in the ICTGPlayerNFT.Sale event (leave blank for no comment)
    /// @return tokenId of the first token minted
    function purchaseWithRecipient(
        address recipient,
        uint256 quantity,
        string calldata comment
    ) external payable nonReentrant onlyPublicSaleActive returns (uint256) {
        return _handleMint(recipient, quantity, comment);
    }

    function _handleMint(address recipient, uint256 quantity, string memory comment) internal returns (uint256) {
        _requireCanPurchaseQuantity(recipient, quantity);
        _requireCanMintQuantity(quantity);

        uint256 salePrice = _getCTGPlayerNFTStorage().salesConfig.publicSalePrice;

        if (msg.value != salePrice * quantity) {
            revert WrongValueSent(msg.value, salePrice * quantity);
        }

        _mintNFTs(recipient, quantity);

        uint256 firstMintedTokenId = _lastMintedTokenId() - quantity;

        _emitSaleEvents(_msgSender(), recipient, quantity, salePrice, firstMintedTokenId, comment);

        return firstMintedTokenId;
    }

    /// @notice Function to mint NFTs
    /// @dev (important: Does not enforce max supply limit, enforce that limit earlier)
    /// @dev This batches in size of 8 as per recommended by ERC721A creators
    /// @param to address to mint NFTs to
    /// @param quantity number of NFTs to mint
    function _mintNFTs(address to, uint256 quantity) internal {
        do {
            uint256 toMint = quantity > MAX_MINT_BATCH_SIZE ? MAX_MINT_BATCH_SIZE : quantity;
            _mint({to: to, quantity: toMint});
            quantity -= toMint;
        } while (quantity > 0);
    }

    /// @notice Merkle-tree based presale purchase function
    /// @param quantity quantity to purchase
    /// @param maxQuantity max quantity that can be purchased via merkle proof #
    /// @param pricePerToken price that each token is purchased at
    /// @param merkleProof proof for presale mint
    function purchasePresale(uint256 quantity, uint256 maxQuantity, uint256 pricePerToken, bytes32[] calldata merkleProof) external payable returns (uint256) {
        return _handlePurchasePresale(msg.sender, quantity, maxQuantity, pricePerToken, merkleProof, "");
    }

    /// @notice Merkle-tree based presale purchase function
    /// @param recipient NFT recipient
    /// @param quantity quantity to purchase
    /// @param maxQuantity max quantity that can be purchased via merkle proof #
    /// @param pricePerToken price that each token is purchased at
    /// @param merkleProof proof for presale mint
    function purchasePresaleWithRecipient(address recipient, uint256 quantity, uint256 maxQuantity, uint256 pricePerToken, bytes32[] calldata merkleProof) external payable returns (uint256) {
        return _handlePurchasePresale(recipient, quantity, maxQuantity, pricePerToken, merkleProof, "");
    }

    /// @notice Merkle-tree based presale purchase function with a comment
    /// @param quantity quantity to purchase
    /// @param maxQuantity max quantity that can be purchased via merkle proof #
    /// @param pricePerToken price that each token is purchased at
    /// @param merkleProof proof for presale mint
    /// @param comment comment to include in the ICTGPlayerNFT.Sale event
    function purchasePresaleWithComment(
        uint256 quantity,
        uint256 maxQuantity,
        uint256 pricePerToken,
        bytes32[] calldata merkleProof,
        string calldata comment
    ) external payable returns (uint256) {
        return _handlePurchasePresale(msg.sender, quantity, maxQuantity, pricePerToken, merkleProof, comment);
    }

    function _handlePurchasePresale(
        address recipient,
        uint256 quantity,
        uint256 maxQuantity,
        uint256 pricePerToken,
        bytes32[] calldata merkleProof,
        string memory comment
    ) internal nonReentrant onlyPresaleActive returns (uint256) {
        _requireCanMintQuantity(quantity);

        if (msg.value != pricePerToken * quantity) {
            revert WrongValueSent(msg.value, pricePerToken * quantity);
        }

        _requireMerkleApproval(recipient, maxQuantity, pricePerToken, merkleProof);

        _requireCanPurchasePresale(recipient, quantity, maxQuantity);

        _mintNFTs(recipient, quantity);

        uint256 firstMintedTokenId = _lastMintedTokenId() - quantity;

        _emitSaleEvents(msg.sender, recipient, quantity, pricePerToken, firstMintedTokenId, comment);

        return firstMintedTokenId;
    }

    /**
     *** ---------------------------------- ***
     ***                                    ***
     ***     ADMIN MINTING FUNCTIONS        ***
     ***                                    ***
     *** ---------------------------------- ***
     ***/

    //                       ,-.
    //                       `-'
    //                       /|\
    //                        |                             ,----------.
    //                       / \                            |CTGPlayerNFT|
    //                     Caller                           `----+-----'
    //                       |            adminMint()            |
    //                       | ---------------------------------->
    //                       |                                   |
    //                       |                                   |
    //          _________________________________________________________________
    //          ! ALT  /  caller is not admin or minter role?    |               !
    //          !_____/      |                                   |               !
    //          !            | revert Access_MissingRoleOrAdmin()|               !
    //          !            | <----------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |
    //          _________________________________________________________________
    //          ! ALT  /  drop has no tokens left for caller to mint?            !
    //          !_____/      |                                   |               !
    //          !            |       revert Mint_SoldOut()       |               !
    //          !            | <----------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |----.
    //                       |                                   |    | mint tokens
    //                       |                                   |<---'
    //                       |                                   |
    //                       |    return last minted token ID    |
    //                       | <----------------------------------
    //                     Caller                           ,----+-----.
    //                       ,-.                            |CTGPlayerNFT|
    //                       `-'                            `----------'
    //                       /|\
    //                        |
    //                       / \
    /// @notice Mint admin
    /// @param recipient recipient to mint to
    /// @param quantity quantity to mint
    function adminMint(address recipient, uint256 quantity) external onlyRoleOrAdmin(MINTER_ROLE) canMintTokens(quantity) returns (uint256) {
        _mintNFTs(recipient, quantity);

        return _lastMintedTokenId();
    }

    //                       ,-.
    //                       `-'
    //                       /|\
    //                        |                             ,----------.
    //                       / \                            |CTGPlayerNFT|
    //                     Caller                           `----+-----'
    //                       |         adminMintAirdrop()        |
    //                       | ---------------------------------->
    //                       |                                   |
    //                       |                                   |
    //          _________________________________________________________________
    //          ! ALT  /  caller is not admin or minter role?    |               !
    //          !_____/      |                                   |               !
    //          !            | revert Access_MissingRoleOrAdmin()|               !
    //          !            | <----------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |
    //          _________________________________________________________________
    //          ! ALT  /  drop has no tokens left for recipients to mint?        !
    //          !_____/      |                                   |               !
    //          !            |       revert Mint_SoldOut()       |               !
    //          !            | <----------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |
    //                       |                    _____________________________________
    //                       |                    ! LOOP  /  for all recipients        !
    //                       |                    !______/       |                     !
    //                       |                    !              |----.                !
    //                       |                    !              |    | mint tokens    !
    //                       |                    !              |<---'                !
    //                       |                    !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |    return last minted token ID    |
    //                       | <----------------------------------
    //                     Caller                           ,----+-----.
    //                       ,-.                            |CTGPlayerNFT|
    //                       `-'                            `----------'
    //                       /|\
    //                        |
    //                       / \
    /// @dev This mints multiple editions to the given list of addresses.
    /// @param recipients list of addresses to send the newly minted editions to
    function adminMintAirdrop(address[] calldata recipients) external override onlyRoleOrAdmin(MINTER_ROLE) canMintTokens(recipients.length) returns (uint256) {
        uint256 atId = ERC721AStorage.layout()._currentIndex;
        uint256 startAt = atId;

        unchecked {
            for (uint256 endAt = atId + recipients.length; atId < endAt; atId++) {
                _mintNFTs(recipients[atId - startAt], 1);
            }
        }
        return _lastMintedTokenId();
    }

    /**
     *** ---------------------------------- ***
     ***                                    ***
     ***  ADMIN CONFIGURATION FUNCTIONS     ***
     ***                                    ***
     *** ---------------------------------- ***
     ***/

    //                       ,-.
    //                       `-'
    //                       /|\
    //                        |                    ,----------.
    //                       / \                   |CTGPlayerNFT|
    //                     Caller                  `----+-----'
    //                       |        setOwner()        |
    //                       | ------------------------->
    //                       |                          |
    //                       |                          |
    //          ________________________________________________________
    //          ! ALT  /  caller is not admin?          |               !
    //          !_____/      |                          |               !
    //          !            | revert Access_OnlyAdmin()|               !
    //          !            | <-------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                          |
    //                       |                          |----.
    //                       |                          |    | set owner
    //                       |                          |<---'
    //                     Caller                  ,----+-----.
    //                       ,-.                   |CTGPlayerNFT|
    //                       `-'                   `----------'
    //                       /|\
    //                        |
    //                       / \
    /// @dev Set new owner for royalties / opensea
    /// @param newOwner new owner to set
    function setOwner(address newOwner) public onlyAdmin {
        _setOwner(newOwner);
    }

    /// @notice Set a new metadata renderer
    /// @param newRenderer new renderer address to use
    /// @param setupRenderer data to setup new renderer with
    function setMetadataRenderer(IMetadataRenderer newRenderer, bytes memory setupRenderer) external onlyAdmin {
        _getCTGPlayerNFTStorage().config.metadataRenderer = newRenderer;

        if (setupRenderer.length > 0) {
            newRenderer.initializeWithData(setupRenderer);
        }

        emit UpdatedMetadataRenderer({sender: _msgSender(), renderer: newRenderer});

        _notifyMetadataUpdate();
    }

    function updateRoyaltySettings(uint16 newRoyaltyBPS) external onlyAdmin {
        _updateRoyaltySettings(newRoyaltyBPS);
    }

    function _updateRoyaltySettings(uint16 newRoyaltyBPS) internal {
        ICTGPlayerNFT.Configuration storage nftConfig = _getCTGPlayerNFTStorage().config;
        if (newRoyaltyBPS > MAX_ROYALTY_BPS) {
            revert Setup_RoyaltyPercentageTooHigh(MAX_ROYALTY_BPS);
        }
        nftConfig.royaltyBPS = newRoyaltyBPS;
        emit RoyaltySettingsUpdated(nftConfig.royaltyBPS);
    }


    /// @notice Calls the metadata renderer contract to make an update and uses the EIP4906 event to notify
    /// @param data raw calldata to call the metadata renderer contract with.
    /// @dev Only accessible via an admin role
    function callMetadataRenderer(bytes memory data) public onlyAdmin returns (bytes memory) {
        (bool success, bytes memory response) = address(_getCTGPlayerNFTStorage().config.metadataRenderer).call(data);
        if (!success) {
            revert ExternalMetadataRenderer_CallFailed();
        }
        _notifyMetadataUpdate();
        return response;
    }

    //                       ,-.
    //                       `-'
    //                       /|\
    //                        |                             ,----------.
    //                       / \                            |CTGPlayerNFT|
    //                     Caller                           `----+-----'
    //                       |      setSalesConfiguration()      |
    //                       | ---------------------------------->
    //                       |                                   |
    //                       |                                   |
    //          _________________________________________________________________
    //          ! ALT  /  caller is not admin?                   |               !
    //          !_____/      |                                   |               !
    //          !            | revert Access_MissingRoleOrAdmin()|               !
    //          !            | <----------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |----.
    //                       |                                   |    | set funds recipient
    //                       |                                   |<---'
    //                       |                                   |
    //                       |                                   |----.
    //                       |                                   |    | emit FundsRecipientChanged()
    //                       |                                   |<---'
    //                     Caller                           ,----+-----.
    //                       ,-.                            |CTGPlayerNFT|
    //                       `-'                            `----------'
    //                       /|\
    //                        |
    //                       / \
    /// @dev This sets the sales configuration
    /// @param publicSalePrice New public sale price
    /// @param maxSalePurchasePerAddress Max # of purchases (public) per address allowed
    /// @param publicSaleStart unix timestamp when the public sale starts
    /// @param publicSaleEnd unix timestamp when the public sale ends (set to 0 to disable)
    /// @param presaleStart unix timestamp when the presale starts
    /// @param presaleEnd unix timestamp when the presale ends
    /// @param presaleMerkleRoot merkle root for the presale information
    function setSaleConfiguration(
        uint104 publicSalePrice,
        uint32 maxSalePurchasePerAddress,
        uint64 publicSaleStart,
        uint64 publicSaleEnd,
        uint64 presaleStart,
        uint64 presaleEnd,
        bytes32 presaleMerkleRoot
    ) external onlyRoleOrAdmin(SALES_MANAGER_ROLE) {
        ICTGPlayerNFT.SalesConfiguration storage salesConfigLocal = _getCTGPlayerNFTStorage().salesConfig;
        salesConfigLocal.publicSalePrice = publicSalePrice;
        salesConfigLocal.maxSalePurchasePerAddress = maxSalePurchasePerAddress;
        salesConfigLocal.publicSaleStart = publicSaleStart;
        salesConfigLocal.publicSaleEnd = publicSaleEnd;
        salesConfigLocal.presaleStart = presaleStart;
        salesConfigLocal.presaleEnd = presaleEnd;
        salesConfigLocal.presaleMerkleRoot = presaleMerkleRoot;

        emit SalesConfigChanged(_msgSender());
    }

    //                       ,-.
    //                       `-'
    //                       /|\
    //                        |                    ,----------.
    //                       / \                   |CTGPlayerNFT|
    //                     Caller                  `----+-----'
    //                       |        setOwner()        |
    //                       | ------------------------->
    //                       |                          |
    //                       |                          |
    //          ________________________________________________________
    //          ! ALT  /  caller is not admin or SALES_MANAGER_ROLE?    !
    //          !_____/      |                          |               !
    //          !            | revert Access_OnlyAdmin()|               !
    //          !            | <-------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                          |
    //                       |                          |----.
    //                       |                          |    | set sales configuration
    //                       |                          |<---'
    //                       |                          |
    //                       |                          |----.
    //                       |                          |    | emit SalesConfigChanged()
    //                       |                          |<---'
    //                     Caller                  ,----+-----.
    //                       ,-.                   |CTGPlayerNFT|
    //                       `-'                   `----------'
    //                       /|\
    //                        |
    //                       / \
    /// @notice Set a different funds recipient
    /// @param newRecipientAddress new funds recipient address
    function setFundsRecipient(address payable newRecipientAddress) external onlyRoleOrAdmin(SALES_MANAGER_ROLE) {
        _getCTGPlayerNFTStorage().config.fundsRecipient = newRecipientAddress;
        emit FundsRecipientChanged(newRecipientAddress, _msgSender());
    }

    //                       ,-.                  ,-.                      ,-.
    //                       `-'                  `-'                      `-'
    //                       /|\                  /|\                      /|\
    //                        |                    |                        |                      ,----------.
    //                       / \                  / \                      / \                     |CTGPlayerNFT|
    //                     Caller            FeeRecipient            FundsRecipient                `----+-----'
    //                       |                    |           withdraw()   |                            |
    //                       | ------------------------------------------------------------------------->
    //                       |                    |                        |                            |
    //                       |                    |                        |                            |
    //          ________________________________________________________________________________________________________
    //          ! ALT  /  caller is not admin or manager?                  |                            |               !
    //          !_____/      |                    |                        |                            |               !
    //          !            |                    revert Access_WithdrawNotAllowed()                    |               !
    //          !            | <-------------------------------------------------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                    |                        |                            |
    //                       |                    |                   send fee amount                   |
    //                       |                    | <----------------------------------------------------
    //                       |                    |                        |                            |
    //                       |                    |                        |                            |
    //                       |                    |                        |             ____________________________________________________________
    //                       |                    |                        |             ! ALT  /  send unsuccesful?                                 !
    //                       |                    |                        |             !_____/        |                                            !
    //                       |                    |                        |             !              |----.                                       !
    //                       |                    |                        |             !              |    | revert Withdraw_FundsSendFailure()    !
    //                       |                    |                        |             !              |<---'                                       !
    //                       |                    |                        |             !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                    |                        |             !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                    |                        |                            |
    //                       |                    |   foundry.toml                     | send remaining funds amount|
    //                       |                    |                        | <---------------------------
    //                       |                    |                        |                            |
    //                       |                    |                        |                            |
    //                       |                    |                        |             ____________________________________________________________
    //                       |                    |                        |             ! ALT  /  send unsuccesful?                                 !
    //                       |                    |                        |             !_____/        |                                            !
    //                       |                    |                        |             !              |----.                                       !
    //                       |                    |                        |             !              |    | revert Withdraw_FundsSendFailure()    !
    //                       |                    |                        |             !              |<---'                                       !
    //                       |                    |                        |             !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                    |                        |             !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                     Caller            FeeRecipient            FundsRecipient                ,----+-----.
    //                       ,-.                  ,-.                      ,-.                     |CTGPlayerNFT|
    //                       `-'                  `-'                      `-'                     `----------'
    //                       /|\                  /|\                      /|\
    //                        |                    |                        |
    //                       / \                  / \                      / \
    /// @notice This withdraws ETH from the contract to the contract owner.
    function withdraw() external nonReentrant {
        address sender = _msgSender();

        address payable fundsRecipient = _getCTGPlayerNFTStorage().config.fundsRecipient;

        if (fundsRecipient == address(0)) {
            revert ZeroFundsRecipientNotAllowed();
        }

        _verifyWithdrawAccess(sender);

        uint256 funds = address(this).balance;

        // Payout recipient
        (bool successFunds, ) = fundsRecipient.call{value: funds, gas: FUNDS_SEND_GAS_LIMIT}("");
        if (!successFunds) {
            revert Withdraw_FundsSendFailure();
        }

        // Emit event for indexing
        emit FundsWithdrawn(_msgSender(), fundsRecipient, funds, address(0), 0);
    }

    function _verifyWithdrawAccess(address msgSender) internal view {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msgSender) && !hasRole(SALES_MANAGER_ROLE, msgSender) && msgSender != _getCTGPlayerNFTStorage().config.fundsRecipient
        ) {
            revert Access_WithdrawNotAllowed();
        }
    }

    //                       ,-.
    //                       `-'
    //                       /|\
    //                        |                             ,----------.
    //                       / \                            |CTGPlayerNFT|
    //                     Caller                           `----+-----'
    //                       |       finalizeOpenEdition()       |
    //                       | ---------------------------------->
    //                       |                                   |
    //                       |                                   |
    //          _________________________________________________________________
    //          ! ALT  /  caller is not admin or SALES_MANAGER_ROLE?             !
    //          !_____/      |                                   |               !
    //          !            | revert Access_MissingRoleOrAdmin()|               !
    //          !            | <----------------------------------               !
    //          !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //          !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |
    //                       |                    _______________________________________________________________________
    //                       |                    ! ALT  /  drop is not an open edition?                                 !
    //                       |                    !_____/        |                                                       !
    //                       |                    !              |----.                                                  !
    //                       |                    !              |    | revert Admin_UnableToFinalizeNotOpenEdition()    !
    //                       |                    !              |<---'                                                  !
    //                       |                    !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                    !~[noop]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //                       |                                   |
    //                       |                                   |----.
    //                       |                                   |    | set config edition size
    //                       |                                   |<---'
    //                       |                                   |
    //                       |                                   |----.
    //                       |                                   |    | emit OpenMintFinalized()
    //                       |                                   |<---'
    //                     Caller                           ,----+-----.
    //                       ,-.                            |CTGPlayerNFT|
    //                       `-'                            `----------'
    //                       /|\
    //                        |
    //                       / \
    /// @notice Admin function to finalize and open edition sale
    function finalizeOpenEdition() external onlyRoleOrAdmin(SALES_MANAGER_ROLE) {
        CTGPlayerNFTStorage storage nftStorage = _getCTGPlayerNFTStorage();
        if (nftStorage.config.editionSize != type(uint64).max) {
            revert Admin_UnableToFinalizeNotOpenEdition();
        }

        nftStorage.config.editionSize = uint64(_totalMinted());
        emit OpenMintFinalized(_msgSender(), nftStorage.config.editionSize);
    }

    /**
     *** ---------------------------------- ***
     ***                                    ***
     ***      GENERAL GETTER FUNCTIONS      ***
     ***                                    ***
     *** ---------------------------------- ***
     ***/

    /// @notice Simple override for owner interface.
    /// @return user owner address
    function owner() public view override(OwnableSkeleton, ICTGPlayerNFT) returns (address) {
        return super.owner();
    }

    /// @notice Contract URI Getter, proxies to metadataRenderer
    /// @return Contract URI
    function contractURI() external view returns (string memory) {
        return _getCTGPlayerNFTStorage().config.metadataRenderer.contractURI();
    }

    /// @notice Getter for metadataRenderer contract
    function metadataRenderer() external view returns (IMetadataRenderer) {
        return IMetadataRenderer(_getCTGPlayerNFTStorage().config.metadataRenderer);
    }

    /// @notice Token URI Getter, proxies to metadataRenderer
    /// @param tokenId id of token to get URI for
    /// @return Token URI
    function tokenURI(uint256 tokenId) public view override(IERC721AUpgradeable, ERC721AUpgradeable) returns (string memory) {
        if (!_exists(tokenId)) {
            revert IERC721AUpgradeable.URIQueryForNonexistentToken();
        }

        return _getCTGPlayerNFTStorage().config.metadataRenderer.tokenURI(tokenId);
    }

    /// @notice Internal function to notify that all metadata may/was updated in the update
    /// @dev Since we don't know what tokens were updated, most calls to a metadata renderer
    ///      update the metadata we can assume all tokens metadata changed
    function _notifyMetadataUpdate() internal {
        uint256 totalMinted = _totalMinted();

        // If we have tokens to notify about
        if (totalMinted > 0) {
            emit BatchMetadataUpdate(_startTokenId(), totalMinted + _startTokenId());
        }
    }

    function _requireCanMintQuantity(uint256 quantity) internal view {
        if (quantity + _totalMinted() > _getCTGPlayerNFTStorage().config.editionSize) {
            revert Mint_SoldOut();
        }
    }

    function _requireCanPurchaseQuantity(address recipient, uint256 quantity) internal view {
        ICTGPlayerNFT.SalesConfiguration storage salesConfigLocal = _getCTGPlayerNFTStorage().salesConfig;
        // If max purchase per address == 0 there is no limit.
        // Any other number, the per address mint limit is that.
        if (
            salesConfigLocal.maxSalePurchasePerAddress != 0 &&
            // Change for CTG: public sale purchase per address _does not_ remove presale mint limit counts. The mint count is global.
            _numberMinted(recipient) + quantity > salesConfigLocal.maxSalePurchasePerAddress
            // _numberMinted(recipient) + quantity - _getCTGPlayerNFTStorage().presaleMintsByAddress[recipient] > salesConfigLocal.maxSalePurchasePerAddress
        ) {
            revert Purchase_TooManyForAddress();
        }
    }

    function _requireCanPurchasePresale(address recipient, uint256 quantity, uint256 maxQuantity) internal view {
        if (_numberMinted(recipient) + quantity > maxQuantity) {
            revert Presale_TooManyForAddress();
        }
    }

    function _requireMerkleApproval(address recipient, uint256 maxQuantity, uint256 pricePerToken, bytes32[] calldata merkleProof) internal view {
        if (
            !MerkleProof.verify(
                merkleProof,
                _getCTGPlayerNFTStorage().salesConfig.presaleMerkleRoot,
                keccak256(
                    // address, uint256, uint256
                    abi.encode(recipient, maxQuantity, pricePerToken)
                )
            )
        ) {
            revert Presale_MerkleNotApproved();
        }
    }

    function _emitSaleEvents(
        address msgSender,
        address recipient,
        uint256 quantity,
        uint256 pricePerToken,
        uint256 firstMintedTokenId,
        string memory comment
    ) internal {
        emit ICTGPlayerNFT.Sale({to: recipient, quantity: quantity, pricePerToken: pricePerToken, firstPurchasedTokenId: firstMintedTokenId});

        if (bytes(comment).length > 0) {
            emit ICTGPlayerNFT.MintComment({
                sender: msgSender,
                tokenContract: address(this),
                tokenId: firstMintedTokenId,
                quantity: quantity,
                comment: comment
            });
        }
    }

    /// @notice ERC165 supports interface
    /// @param interfaceId interface id to check if supported
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(IERC165, IERC721AUpgradeable, ERC721AUpgradeable, AccessControlUpgradeable) returns (bool) {
        return
            super.supportsInterface(interfaceId) ||
            ERC721AUpgradeable.supportsInterface(interfaceId) ||
            type(IOwnable).interfaceId == interfaceId ||
            type(IERC2981).interfaceId == interfaceId ||
            // Because the EIP-4906 spec is event-based a numerically relevant interfaceId is used.
            bytes4(0x49064906) == interfaceId ||
            type(ICTGPlayerNFT).interfaceId == interfaceId;
    }
}
