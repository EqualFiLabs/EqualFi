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

/// @notice ERC-8004 transfer callback interface
interface IERC8004Callback {
    function onAgentTransfer(uint256 agentId) external;
}

/// @notice ERC-8004 identity registry interface (selectors for ERC-165)
interface IERC8004Identity {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    function register() external returns (uint256 agentId);
    function register(string calldata agentURI) external returns (uint256 agentId);
    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId);
    function setAgentURI(uint256 agentId, string calldata newURI) external;
    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory);
    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external;
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;
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
        bytes memory data = _diamondStaticCall(abi.encodeWithSignature("getAgentURI(uint256)", tokenId));
        return abi.decode(data, (string));
    }

    /// @notice Check if a token exists
    /// @param tokenId The token ID to check
    /// @return True if the token exists
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice ERC-8004 register forwarding (no metadata)
    function register() external returns (uint256 agentId) {
        bytes memory data = _diamondCall(abi.encodeWithSignature("register()"));
        return abi.decode(data, (uint256));
    }

    /// @notice ERC-8004 register forwarding with agentURI
    function register(string calldata agentURI) external returns (uint256 agentId) {
        bytes memory data = _diamondCall(abi.encodeWithSignature("register(string)", agentURI));
        return abi.decode(data, (uint256));
    }

    /// @notice ERC-8004 register forwarding with metadata
    function register(string calldata agentURI, IERC8004Identity.MetadataEntry[] calldata metadata)
        external
        returns (uint256 agentId)
    {
        bytes memory data = _diamondCall(abi.encodeWithSignature("register(string,(string,bytes)[])", agentURI, metadata));
        return abi.decode(data, (uint256));
    }

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        _diamondCall(abi.encodeWithSignature("setAgentURI(uint256,string)", agentId, newURI));
    }

    function getAgentURI(uint256 agentId) external view returns (string memory) {
        bytes memory data = _diamondStaticCall(abi.encodeWithSignature("getAgentURI(uint256)", agentId));
        return abi.decode(data, (string));
    }

    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory) {
        bytes memory data = _diamondStaticCall(
            abi.encodeWithSignature("getMetadata(uint256,string)", agentId, metadataKey)
        );
        return abi.decode(data, (bytes));
    }

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        _diamondCall(abi.encodeWithSignature("setMetadata(uint256,string,bytes)", agentId, metadataKey, metadataValue));
    }

    function setAgentWallet(
        uint256 agentId,
        address newWallet,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _diamondCall(
            abi.encodeWithSignature("setAgentWallet(uint256,address,uint256,bytes)", agentId, newWallet, deadline, signature)
        );
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        bytes memory data = _diamondStaticCall(abi.encodeWithSignature("getAgentWallet(uint256)", agentId));
        return abi.decode(data, (address));
    }

    function getAgentNonce(uint256 agentId) external view returns (uint256) {
        bytes memory data = _diamondStaticCall(abi.encodeWithSignature("getAgentNonce(uint256)", agentId));
        return abi.decode(data, (uint256));
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
        if (interfaceId == type(IERC8004Identity).interfaceId) {
            return true;
        }
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

            IERC8004Callback(diamond).onAgentTransfer(tokenId);
        }
        
        return from;
    }

    function _diamondCall(bytes memory callData) internal returns (bytes memory data) {
        address diamondAddr = diamond;
        require(diamondAddr != address(0), "PositionNFT: diamond not set");
        (bool ok, bytes memory result) = diamondAddr.call(callData);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }

    function _diamondStaticCall(bytes memory callData) internal view returns (bytes memory data) {
        address diamondAddr = diamond;
        require(diamondAddr != address(0), "PositionNFT: diamond not set");
        (bool ok, bytes memory result) = diamondAddr.staticcall(callData);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}
