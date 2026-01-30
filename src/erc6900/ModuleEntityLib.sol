// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ModuleEntity} from "./ModuleTypes.sol";

/// @title ModuleEntityLib
/// @notice Pack/unpack helpers for ModuleEntity
library ModuleEntityLib {
    function pack(address module, uint32 entityId) internal pure returns (ModuleEntity) {
        return ModuleEntity.wrap(bytes24(bytes20(module)) | bytes24(uint192(entityId)));
    }

    function unpack(ModuleEntity entity) internal pure returns (address module, uint32 entityId) {
        bytes24 raw = ModuleEntity.unwrap(entity);
        module = address(bytes20(raw));
        entityId = uint32(uint192(raw));
    }
}
