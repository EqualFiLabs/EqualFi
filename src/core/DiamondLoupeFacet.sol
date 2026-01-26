// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";

/// @dev Implements EIP-2535 Diamond loupe functions
contract DiamondLoupeFacet is IDiamondLoupe {
    // Facet function selectors are stored in diamond storage
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        facets_ = new Facet[](selectorCount);

        uint256[] memory numFacetSelectors = new uint256[](selectorCount);
        uint256 numFacets;
        for (uint256 selectorIndex; selectorIndex < selectorCount; selectorIndex++) {
            bytes4 selector = ds.selectors[selectorIndex];
            address facetAddr = ds.facetAddressAndSelectorPosition[selector].facetAddress;

            bool selectorExists;
            for (uint256 facetIndex; facetIndex < numFacets; facetIndex++) {
                if (facets_[facetIndex].facetAddress == facetAddr) {
                    selectorExists = true;
                    break;
                }
            }

            if (!selectorExists) {
                facets_[numFacets].facetAddress = facetAddr;
                facets_[numFacets].functionSelectors = new bytes4[](selectorCount);
                numFacets++;
            }
        }

        facets_ = sliceFacets(ds, facets_, numFacets, numFacetSelectors);
    }

    function sliceFacets(
        LibDiamond.DiamondStorage storage ds,
        Facet[] memory facets_,
        uint256 numFacets,
        uint256[] memory numFacetSelectors
    ) internal view returns (Facet[] memory) {
        uint256 selectorCount = ds.selectors.length;
        for (uint256 selectorIndex; selectorIndex < selectorCount; selectorIndex++) {
            bytes4 selector = ds.selectors[selectorIndex];
            address facetAddress_ = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            for (uint256 facetIndex; facetIndex < numFacets; facetIndex++) {
                if (facetAddress_ == facets_[facetIndex].facetAddress) {
                    facets_[facetIndex].functionSelectors[numFacetSelectors[facetIndex]] = selector;
                    numFacetSelectors[facetIndex]++;
                    break;
                }
            }
        }

        for (uint256 facetIndex; facetIndex < numFacets; facetIndex++) {
            bytes4[] memory selectors = facets_[facetIndex].functionSelectors;
            uint256 selectorLength = numFacetSelectors[facetIndex];
            // shrink array
            bytes4[] memory trimmed = new bytes4[](selectorLength);
            for (uint256 i; i < selectorLength; i++) {
                trimmed[i] = selectors[i];
            }
            facets_[facetIndex].functionSelectors = trimmed;
        }

        // shrink facets array
        Facet[] memory trimmedFacets = new Facet[](numFacets);
        for (uint256 facetIndex; facetIndex < numFacets; facetIndex++) {
            trimmedFacets[facetIndex] = facets_[facetIndex];
        }
        return trimmedFacets;
    }

    function facetFunctionSelectors(address _facet) external view override returns (bytes4[] memory facetSelectors_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        facetSelectors_ = new bytes4[](selectorCount);
        uint256 count;
        for (uint256 selectorIndex; selectorIndex < selectorCount; selectorIndex++) {
            bytes4 selector = ds.selectors[selectorIndex];
            if (ds.facetAddressAndSelectorPosition[selector].facetAddress == _facet) {
                facetSelectors_[count] = selector;
                count++;
            }
        }
        // trim
        bytes4[] memory trimmed = new bytes4[](count);
        for (uint256 i; i < count; i++) {
            trimmed[i] = facetSelectors_[i];
        }
        return trimmed;
    }

    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = ds.selectors.length;
        facetAddresses_ = new address[](selectorCount);
        uint256 count;
        for (uint256 selectorIndex; selectorIndex < selectorCount; selectorIndex++) {
            address facetAddr = ds.facetAddressAndSelectorPosition[ds.selectors[selectorIndex]].facetAddress;
            bool exists;
            for (uint256 facetIndex; facetIndex < count; facetIndex++) {
                if (facetAddresses_[facetIndex] == facetAddr) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                facetAddresses_[count] = facetAddr;
                count++;
            }
        }
        // trim
        address[] memory trimmed = new address[](count);
        for (uint256 i; i < count; i++) {
            trimmed[i] = facetAddresses_[i];
        }
        return trimmed;
    }

    function facetAddress(bytes4 _functionSelector) external view override returns (address facetAddress_) {
        facetAddress_ = LibDiamond.diamondStorage().facetAddressAndSelectorPosition[_functionSelector].facetAddress;
    }

    function supportsInterface(bytes4 _interfaceId) external view override returns (bool) {
        return LibDiamond.supportsInterface(_interfaceId);
    }
}
