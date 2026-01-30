// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ModuleEntity, ValidationConfig} from "./ModuleTypes.sol";
import {ModuleEntityLib} from "./ModuleEntityLib.sol";

/// @title ValidationConfigLib
/// @notice Pack/unpack helpers for ValidationConfig
library ValidationConfigLib {
    function pack(
        address module,
        uint32 entityId,
        bool isGlobal,
        bool isSignatureValidation,
        bool isUserOpValidation
    ) internal pure returns (ValidationConfig) {
        uint8 flags = (isGlobal ? 4 : 0) | (isSignatureValidation ? 2 : 0) | (isUserOpValidation ? 1 : 0);
        bytes24 packed = ModuleEntity.unwrap(ModuleEntityLib.pack(module, entityId));
        return ValidationConfig.wrap(bytes25(packed) | bytes25(uint200(flags)));
    }

    function unpack(ValidationConfig config)
        internal
        pure
        returns (address module, uint32 entityId, bool isGlobal, bool isSignatureValidation, bool isUserOpValidation)
    {
        bytes25 raw = ValidationConfig.unwrap(config);
        (module, entityId) = ModuleEntityLib.unpack(ModuleEntity.wrap(bytes24(raw)));
        uint8 flags = uint8(uint200(raw));
        isGlobal = (flags & 4) != 0;
        isSignatureValidation = (flags & 2) != 0;
        isUserOpValidation = (flags & 1) != 0;
    }
}
