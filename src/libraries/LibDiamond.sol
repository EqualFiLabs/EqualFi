// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IERC165} from "../interfaces/IERC165.sol";

/// @notice Minimal Diamond storage and helpers from mudgen's diamond-2
library LibDiamond {
    bytes32 internal constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct FacetAddressAndSelectorPosition {
        address facetAddress;
        uint16 selectorPosition; // position in selectors array
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndSelectorPosition) facetAddressAndSelectorPosition;
        bytes4[] selectors;
        mapping(bytes4 => bool) supportedInterfaces;
        address contractOwner;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function setContractOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function enforceIsContractOwner() internal view {
        require(msg.sender == diamondStorage().contractOwner, "LibDiamond: must be owner");
    }

    function addReplaceRemoveFacetSelectors(
        IDiamondCut.FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    ) internal {
        for (uint256 facetIndex; facetIndex < _diamondCut.length; facetIndex++) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else {
                revert("LibDiamond: incorrect FacetCutAction");
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "LibDiamond: no selectors");
        DiamondStorage storage ds = diamondStorage();
        require(_facetAddress != address(0), "LibDiamond: facet is zero");

        uint16 selectorCount = uint16(ds.selectors.length);
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            require(ds.facetAddressAndSelectorPosition[selector].facetAddress == address(0), "LibDiamond: exists");
            ds.facetAddressAndSelectorPosition[selector] =
                FacetAddressAndSelectorPosition({facetAddress: _facetAddress, selectorPosition: selectorCount});
            ds.selectors.push(selector);
            selectorCount++;
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "LibDiamond: no selectors");
        DiamondStorage storage ds = diamondStorage();
        require(_facetAddress != address(0), "LibDiamond: facet is zero");

        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            FacetAddressAndSelectorPosition memory old = ds.facetAddressAndSelectorPosition[selector];
            address oldFacetAddress = old.facetAddress;
            require(oldFacetAddress != _facetAddress, "LibDiamond: same facet");
            require(oldFacetAddress != address(0), "LibDiamond: selector missing");
            ds.facetAddressAndSelectorPosition[selector].facetAddress = _facetAddress;
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "LibDiamond: no selectors");
        DiamondStorage storage ds = diamondStorage();
        require(_facetAddress == address(0), "LibDiamond: facet address must be zero");

        uint16 selectorCount = uint16(ds.selectors.length);
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            FacetAddressAndSelectorPosition memory old = ds.facetAddressAndSelectorPosition[selector];
            require(old.facetAddress != address(0), "LibDiamond: selector missing");

            // swap and pop selectors array
            uint16 lastSelectorPosition = selectorCount - 1;
            bytes4 lastSelector = ds.selectors[lastSelectorPosition];
            if (old.selectorPosition != lastSelectorPosition) {
                ds.selectors[old.selectorPosition] = lastSelector;
                ds.facetAddressAndSelectorPosition[lastSelector].selectorPosition = old.selectorPosition;
            }
            ds.selectors.pop();
            delete ds.facetAddressAndSelectorPosition[selector];
            selectorCount--;
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            require(_calldata.length == 0, "LibDiamond: _init is zero but calldata is not empty");
            return;
        }
        require(_calldata.length > 0, "LibDiamond: calldata is empty");
        if (_init != address(this)) {
            require(hasContractCode(_init), "LibDiamond: _init no code");
        }
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        require(success, string(error));
    }

    function hasContractCode(address _contract) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_contract)
        }
        return size > 0;
    }

    function supportsInterface(bytes4 _interfaceId) internal view returns (bool) {
        return diamondStorage().supportedInterfaces[_interfaceId];
    }
}
