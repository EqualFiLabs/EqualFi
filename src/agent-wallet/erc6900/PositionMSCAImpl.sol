// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC721BoundMSCA} from "@agent-wallet-core/core/ERC721BoundMSCA.sol";
import {ModuleEntity, ValidationFlags} from "@agent-wallet-core/libraries/ModuleTypes.sol";
import {MSCAStorage} from "@agent-wallet-core/libraries/MSCAStorage.sol";

/// @title PositionMSCAImpl
/// @notice Concrete ERC-6900 MSCA implementation for ERC-6551 registry deployments
contract PositionMSCAImpl is ERC721BoundMSCA {
    string internal constant EQUALFI_ACCOUNT_ID = "equallend.position-tba.1.0.0";

    constructor(address entryPoint_) ERC721BoundMSCA(entryPoint_) {}

    function accountId() external pure override returns (string memory) {
        return EQUALFI_ACCOUNT_ID;
    }

    /// @notice Check whether a validation module is installed for a given config.
    /// @dev Returns true if the module is installed and validation data exists for the validation function.
    function isValidationInstalled(bytes25 validationConfig) external view returns (bool) {
        bytes25 raw = validationConfig;
        ModuleEntity validationFunction = ModuleEntity.wrap(bytes24(raw));
        address module = address(bytes20(raw));
        MSCAStorage.Layout storage ds = MSCAStorage.layout();
        if (!ds.installedModules[module]) {
            return false;
        }
        MSCAStorage.ValidationData storage data = ds.validationData[validationFunction];
        return ValidationFlags.unwrap(data.flags) != 0 || data.selectors.length > 0;
    }
}
