// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenDataLib} from "../../src/erc6900/TokenDataLib.sol";

contract TokenDataHarness {
    function readTokenData() external view returns (bytes32, uint256, address, uint256) {
        return TokenDataLib.getTokenData();
    }
}

/// @notice Property-based tests for token data immutability
/// forge-config: default.fuzz.runs = 100
contract TokenDataLibPropertyTest is Test {
    /// @notice **Feature: erc6900-modular-tba, Property 4: Token Data Immutability**
    /// @notice Token data read from bytecode should remain consistent
    /// @notice **Validates: Requirements 3.2**
    function testProperty_TokenDataImmutability(
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) public {
        TokenDataHarness harness = new TokenDataHarness();

        bytes memory footer = abi.encode(salt, chainId, tokenContract, tokenId);
        bytes memory code = bytes.concat(type(TokenDataHarness).runtimeCode, footer);
        vm.etch(address(harness), code);

        (bytes32 s1, uint256 c1, address t1, uint256 id1) = harness.readTokenData();
        (bytes32 s2, uint256 c2, address t2, uint256 id2) = harness.readTokenData();

        assertEq(s1, salt, "salt mismatch");
        assertEq(c1, chainId, "chainId mismatch");
        assertEq(t1, tokenContract, "tokenContract mismatch");
        assertEq(id1, tokenId, "tokenId mismatch");

        assertEq(s2, s1, "salt changed");
        assertEq(c2, c1, "chainId changed");
        assertEq(t2, t1, "tokenContract changed");
        assertEq(id2, id1, "tokenId changed");
    }
}
