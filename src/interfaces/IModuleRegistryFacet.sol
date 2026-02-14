// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IModuleRegistryFacet {
    function registerModule(bytes32 metadataHash) external payable returns (uint256 moduleId);
    function setModuleOwner(uint256 moduleId, address newOwner) external;
    function pauseModule(uint256 moduleId) external;
    function unpauseModule(uint256 moduleId) external;

    function setModuleCreationFee(uint256 fee) external;
    function setDefaultModuleAumBps(uint16 bps) external;
    function setModuleAumBps(uint256 moduleId, uint16 bps) external;
    function setModuleAumBounds(uint16 minBps, uint16 maxBps) external;
    function setModuleDeactivationGraceEpochs(uint16 epochs) external;
    function setModuleAciPaused(bool paused) external;
}
