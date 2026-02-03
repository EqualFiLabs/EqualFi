// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC6551Account {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);

    function owner() external view returns (address);

    function nonce() external view returns (uint256);

    function isValidSigner(address signer, bytes calldata data) external view returns (bytes4 magicValue);
}
