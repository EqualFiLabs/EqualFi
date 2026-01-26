// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "./IERC165.sol";

interface IDiamondLoupe is IERC165 {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    function facets() external view returns (Facet[] memory facets_);

    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);

    function facetAddresses() external view returns (address[] memory facetAddresses_);

    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}
