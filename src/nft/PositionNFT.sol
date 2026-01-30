// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {InvalidTokenId} from "../libraries/Errors.sol";

/// @notice Interface for direct-offer hooks from the Diamond (cancellation/checks)
interface IDirectOfferCanceller {
    function cancelOffersForPosition(bytes32 positionKey) external;
    function hasOpenOffers(bytes32 positionKey) external view returns (bool);
}

interface IAgentURIDiamond {
    function getAgentURI(uint256 agentId) external view returns (string memory);
}

/// @title PositionNFT
/// @notice ERC-721 NFT representing isolated account containers in EqualLend pools
/// @dev Each NFT represents a position that can hold deposits, loans, and yield
contract PositionNFT is ERC721Enumerable, ReentrancyGuard {
    error PositionNFTHasOpenOffers(bytes32 positionKey);

    /// @notice Counter for generating unique token IDs
    uint256 public nextTokenId;

    /// @notice Mapping from token ID to pool ID
    mapping(uint256 => uint256) public tokenToPool;

    /// @notice Mapping from token ID to creation timestamp
    mapping(uint256 => uint40) public tokenCreationTime;

    /// @notice Emitted when a new Position NFT is minted
    /// @param tokenId The unique token ID
    /// @param owner The address that owns the NFT
    /// @param poolId The pool ID associated with this position
    event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);

    /// @notice Constructor initializes the ERC721 token
    constructor() ERC721("EqualLend Position", "ELPOS") {
        nextTokenId = 1; // Start token IDs at 1
    }

    /// @notice Address authorized to mint Position NFTs (typically the PositionNFTFacet)
    address public minter;

    /// @notice Address of the Diamond contract for querying pool data
    address public diamond;

    /// @notice Emitted when the minter address is updated
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    /// @notice Emitted when the diamond address is updated
    event DiamondUpdated(address indexed oldDiamond, address indexed newDiamond);

    /// @notice Set the authorized minter address
    /// @param _minter The new minter address
    function setMinter(address _minter) external {
        require(minter == address(0) || msg.sender == minter, "PositionNFT: unauthorized");
        address oldMinter = minter;
        minter = _minter;
        emit MinterUpdated(oldMinter, _minter);
    }

    /// @notice Set the Diamond contract address for pool data queries
    /// @param _diamond The Diamond contract address
    function setDiamond(address _diamond) external {
        require(diamond == address(0) || msg.sender == minter, "PositionNFT: unauthorized");
        address oldDiamond = diamond;
        diamond = _diamond;
        emit DiamondUpdated(oldDiamond, _diamond);
    }

    /// @notice Mint a new Position NFT for a specific pool
    /// @param to The address to mint the NFT to
    /// @param poolId The pool ID to associate with this position
    /// @return tokenId The newly minted token ID
    function mint(address to, uint256 poolId) 
        external 
        nonReentrant 
        returns (uint256 tokenId) 
    {
        require(msg.sender == minter, "PositionNFT: only minter");
        
        tokenId = nextTokenId++;
        
        _safeMint(to, tokenId);
        
        tokenToPool[tokenId] = poolId;
        tokenCreationTime[tokenId] = uint40(block.timestamp);
        
        emit PositionMinted(tokenId, to, poolId);
    }

    /// @notice Get the position key for a given token ID
    /// @dev Position key is used to index into PoolData mappings
    /// @param tokenId The token ID
    /// @return The derived position key
    function getPositionKey(uint256 tokenId) public view returns (bytes32) {
        if (!_exists(tokenId)) {
            revert InvalidTokenId(tokenId);
        }
        return LibPositionNFT.getPositionKey(address(this), tokenId);
    }

    /// @notice Get the pool ID associated with a token
    /// @param tokenId The token ID
    /// @return The pool ID
    function getPoolId(uint256 tokenId) external view returns (uint256) {
        if (!_exists(tokenId)) {
            revert InvalidTokenId(tokenId);
        }
        return tokenToPool[tokenId];
    }

    /// @notice Get the creation timestamp of a token
    /// @param tokenId The token ID
    /// @return The creation timestamp
    function getCreationTime(uint256 tokenId) external view returns (uint40) {
        if (!_exists(tokenId)) {
            revert InvalidTokenId(tokenId);
        }
        return tokenCreationTime[tokenId];
    }

    /// @notice Return the ERC-8004 agent registration file URI
    /// @param tokenId The token ID
    /// @return Registration file URI
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override 
        returns (string memory) 
    {
        if (!_exists(tokenId)) {
            revert InvalidTokenId(tokenId);
        }
        if (diamond != address(0)) {
            return IAgentURIDiamond(diamond).getAgentURI(tokenId);
        }
        return super.tokenURI(tokenId);
    }

    /// @notice Check if a token exists
    /// @param tokenId The token ID to check
    /// @return True if the token exists
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Override supportsInterface to include ERC721Enumerable
    /// @param interfaceId The interface identifier
    /// @return True if the interface is supported
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Hook called during token transfers (mint, transfer, burn)
    /// @dev Position key remains unchanged during transfer - it's derived from (contract, tokenId)
    /// @dev All position data (principal, loans, yield) stays with the position key
    /// @dev New owner inherits all deposits and obligations associated with the NFT
    /// @param to The address receiving the token (address(0) for burning)
    /// @param tokenId The token being transferred
    /// @param auth The address authorized to perform the transfer
    /// @return from The previous owner of the token (address(0) for minting)
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override(ERC721Enumerable) returns (address) {
        address from = super._update(to, tokenId, auth);
        
        // Position key derivation: address(uint160(uint256(keccak256(abi.encodePacked(nftContract, tokenId)))))
        // This key is deterministic and depends only on the contract address and token ID
        // Therefore, it remains unchanged when ownership transfers from 'from' to 'to'
        
        // All position data in PoolData mappings uses this position key:
        // - userPrincipal[positionKey]: deposit amount
        // - userFeeIndex[positionKey]: fee-index checkpoint
        // - userMaintenanceIndex[positionKey]: maintenance-index checkpoint
        // - userAccruedYield[positionKey]: accrued yield
        // - externalCollateral[positionKey]: external collateral
        // - rollingLoans[positionKey]: rolling credit loan
        // - fixedTermLoans[loanId]: fixed-term loans (where borrower = positionKey)
        // - userFixedLoanIds[positionKey]: array of loan IDs
        
        // Since the position key doesn't change, all this data automatically transfers
        // to the new owner. The new owner can operate on the NFT and access all
        // deposits, loans, and yield associated with it.
        
        // Block transfers while outstanding direct offers exist (checked via the diamond, if set).
        if (from != address(0) && to != address(0) && from != to && diamond != address(0)) {
            bytes32 positionKey = LibPositionNFT.getPositionKey(address(this), tokenId);
            if (IDirectOfferCanceller(diamond).hasOpenOffers(positionKey)) {
                revert PositionNFTHasOpenOffers(positionKey);
            }
        }
        
        return from;
    }

}
