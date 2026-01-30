// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title TokenDataLib
/// @notice Extract ERC-6551 token data appended to runtime bytecode
library TokenDataLib {
    function getTokenData()
        internal
        view
        returns (bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
    {
        bytes memory footer = new bytes(0x80);
        assembly {
            let size := extcodesize(address())
            if lt(size, 0x80) {
                revert(0, 0)
            }
            extcodecopy(address(), add(footer, 0x20), sub(size, 0x80), 0x80)
        }
        (salt, chainId, tokenContract, tokenId) = abi.decode(footer, (bytes32, uint256, address, uint256));
    }
}
