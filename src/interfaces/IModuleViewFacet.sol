// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IModuleViewFacet {
    function getModule(uint256 moduleId)
        external
        view
        returns (address owner, bytes32 metadataHash, bool paused, bool inactive, uint16 aumBps);

    function getModuleEncumbrance(uint256 positionId, uint256 poolId) external view returns (uint256 totalModuleEncumbered);
    function getModuleEncumbranceForModule(uint256 positionId, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256 encumbered);

    function getModuleAumState(uint256 positionId, uint256 poolId, uint256 moduleId)
        external
        view
        returns (
            uint64 lastAccruedEpoch,
            uint256 pendingEpochs_,
            bool delinquent,
            uint64 delinquentSince,
            uint256 lastShortfall,
            uint16 graceEpochs,
            uint256 delinquentEpochs_,
            bool graceSatisfied
        );

    function getModuleAumConfig()
        external
        view
        returns (uint16 defaultBps, uint16 minBps, uint16 maxBps, uint16 deactivationGraceEpochs);

    function isModuleAciPaused() external view returns (bool);
}
