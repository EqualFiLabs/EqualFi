// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {HookConfig, ModuleEntity} from "./ModuleTypes.sol";
import {ModuleEntityLib} from "./ModuleEntityLib.sol";

/// @title HookConfigLib
/// @notice Pack/unpack helpers for HookConfig
library HookConfigLib {
    function pack(
        address module,
        uint32 entityId,
        bool isValidationHook,
        bool hasPre,
        bool hasPost
    ) internal pure returns (HookConfig) {
        uint8 flags = (hasPre ? 4 : 0) | (hasPost ? 2 : 0) | (isValidationHook ? 1 : 0);
        bytes24 packed = ModuleEntity.unwrap(ModuleEntityLib.pack(module, entityId));
        return HookConfig.wrap(bytes25(packed) | bytes25(uint200(flags)));
    }

    function unpack(HookConfig config)
        internal
        pure
        returns (address module, uint32 entityId, bool isValidationHook, bool hasPre, bool hasPost)
    {
        bytes25 raw = HookConfig.unwrap(config);
        (module, entityId) = ModuleEntityLib.unpack(ModuleEntity.wrap(bytes24(raw)));
        uint8 flags = uint8(uint200(raw));
        isValidationHook = (flags & 1) != 0;
        hasPost = (flags & 2) != 0;
        hasPre = (flags & 4) != 0;
    }
}
