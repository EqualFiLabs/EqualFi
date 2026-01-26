// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

contract DiamondCutFacet is IDiamondCut {
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.addReplaceRemoveFacetSelectors(_diamondCut, _init, _calldata);
    }
}
