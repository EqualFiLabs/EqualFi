// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC165} from "../interfaces/IERC165.sol";
import {IERC6900ExecutionModule} from "./IERC6900ExecutionModule.sol";
import {IERC6900Module} from "./IERC6900Module.sol";
import {ExecutionManifest, ManifestExecutionFunction} from "./ModuleTypes.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {IERC6551Account} from "../interfaces/IERC6551Account.sol";

interface IAmmAuctionFacet {
    function createAuction(DerivativeTypes.CreateAuctionParams calldata params) external returns (uint256 auctionId);
    function cancelAuction(uint256 auctionId) external;
}

interface IPositionManagementFacet {
    function rollYieldToPosition(uint256 tokenId, uint256 pid) external;
}

library LibAmmSkillStorage {
    bytes32 internal constant STORAGE_SLOT = keccak256("equallend.erc6900.amm-skill.storage.v1");

    struct AuctionPolicy {
        bool enabled;
        bool allowCancel;
        bool enforcePoolAllowlist;
        uint64 minDuration;
        uint64 maxDuration;
        uint16 minFeeBps;
        uint16 maxFeeBps;
        uint256 minReserveA;
        uint256 maxReserveA;
        uint256 minReserveB;
        uint256 maxReserveB;
    }

    struct RollPolicy {
        bool enabled;
        bool enforcePoolAllowlist;
    }

    struct Layout {
        address diamond;
        AuctionPolicy auctionPolicy;
        RollPolicy rollPolicy;
        mapping(uint256 => bool) allowedPools;
    }

    function layout() internal pure returns (Layout storage ds) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            ds.slot := slot
        }
    }
}

/// @title PositionAgentAmmSkillModule
/// @notice ERC-6900 execution module enabling AMM auction + rollYield capabilities for Position Agents
contract PositionAgentAmmSkillModule is IERC6900ExecutionModule {
    using LibAmmSkillStorage for LibAmmSkillStorage.Layout;

    error AmmSkill_Unauthorized(address caller);
    error AmmSkill_DiamondNotSet();
    error AmmSkill_PolicyDisabled();
    error AmmSkill_CancelDisabled();
    error AmmSkill_PoolNotAllowed(uint256 pid);
    error AmmSkill_DurationOutOfBounds(uint64 duration, uint64 min, uint64 max);
    error AmmSkill_FeeOutOfBounds(uint16 feeBps, uint16 minFeeBps, uint16 maxFeeBps);
    error AmmSkill_ReserveOutOfBounds(uint256 reserve, uint256 minReserve, uint256 maxReserve);

    event DiamondUpdated(address indexed previous, address indexed current);
    event AuctionPolicyUpdated(
        bool enabled,
        bool allowCancel,
        bool enforcePoolAllowlist,
        uint64 minDuration,
        uint64 maxDuration,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint256 minReserveA,
        uint256 maxReserveA,
        uint256 minReserveB,
        uint256 maxReserveB
    );
    event RollPolicyUpdated(bool enabled, bool enforcePoolAllowlist);
    event AllowedPoolUpdated(uint256 indexed poolId, bool allowed);

    event AgentAuctionCreated(address indexed agent, uint256 indexed auctionId);
    event AgentAuctionCancelled(address indexed agent, uint256 indexed auctionId);
    event AgentYieldRolled(address indexed agent, uint256 indexed tokenId, uint256 pid);

    function moduleId() external pure override returns (string memory) {
        return "equallend.amm-auction-skill.1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6900Module).interfaceId ||
            interfaceId == type(IERC6900ExecutionModule).interfaceId;
    }

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function executionManifest() external pure override returns (ExecutionManifest memory manifest) {
        manifest.executionFunctions = new ManifestExecutionFunction[](11);
        manifest.executionFunctions[0] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.createAuction.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[1] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.cancelAuction.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[2] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.rollYieldToPosition.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[3] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.setDiamond.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[4] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.setAuctionPolicy.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[5] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.setRollPolicy.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[6] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.setAllowedPool.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[7] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.getDiamond.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[8] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.getAuctionPolicy.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[9] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.getRollPolicy.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[10] = ManifestExecutionFunction({
            executionSelector: PositionAgentAmmSkillModule.isPoolAllowed.selector,
            skipRuntimeValidation: false,
            allowGlobalValidation: false
        });
    }

    function createAuction(DerivativeTypes.CreateAuctionParams calldata params) external returns (uint256 auctionId) {
        LibAmmSkillStorage.Layout storage ds = LibAmmSkillStorage.layout();
        _enforceAuctionPolicy(ds, params);
        address diamond = ds.diamond;
        if (diamond == address(0)) {
            revert AmmSkill_DiamondNotSet();
        }
        auctionId = IAmmAuctionFacet(diamond).createAuction(params);
        emit AgentAuctionCreated(address(this), auctionId);
    }

    function cancelAuction(uint256 auctionId) external {
        LibAmmSkillStorage.Layout storage ds = LibAmmSkillStorage.layout();
        if (!ds.auctionPolicy.allowCancel) {
            revert AmmSkill_CancelDisabled();
        }
        address diamond = ds.diamond;
        if (diamond == address(0)) {
            revert AmmSkill_DiamondNotSet();
        }
        IAmmAuctionFacet(diamond).cancelAuction(auctionId);
        emit AgentAuctionCancelled(address(this), auctionId);
    }

    function rollYieldToPosition(uint256 tokenId, uint256 pid) external {
        LibAmmSkillStorage.Layout storage ds = LibAmmSkillStorage.layout();
        _enforceRollPolicy(ds, pid);
        address diamond = ds.diamond;
        if (diamond == address(0)) {
            revert AmmSkill_DiamondNotSet();
        }
        IPositionManagementFacet(diamond).rollYieldToPosition(tokenId, pid);
        emit AgentYieldRolled(address(this), tokenId, pid);
    }

    function setDiamond(address diamond) external {
        _requireOwner();
        LibAmmSkillStorage.Layout storage ds = LibAmmSkillStorage.layout();
        address previous = ds.diamond;
        ds.diamond = diamond;
        emit DiamondUpdated(previous, diamond);
    }

    function setAuctionPolicy(LibAmmSkillStorage.AuctionPolicy calldata policy) external {
        _requireOwner();
        LibAmmSkillStorage.Layout storage ds = LibAmmSkillStorage.layout();
        ds.auctionPolicy = policy;
        emit AuctionPolicyUpdated(
            policy.enabled,
            policy.allowCancel,
            policy.enforcePoolAllowlist,
            policy.minDuration,
            policy.maxDuration,
            policy.minFeeBps,
            policy.maxFeeBps,
            policy.minReserveA,
            policy.maxReserveA,
            policy.minReserveB,
            policy.maxReserveB
        );
    }

    function setRollPolicy(LibAmmSkillStorage.RollPolicy calldata policy) external {
        _requireOwner();
        LibAmmSkillStorage.layout().rollPolicy = policy;
        emit RollPolicyUpdated(policy.enabled, policy.enforcePoolAllowlist);
    }

    function setAllowedPool(uint256 poolId, bool allowed) external {
        _requireOwner();
        LibAmmSkillStorage.layout().allowedPools[poolId] = allowed;
        emit AllowedPoolUpdated(poolId, allowed);
    }

    function isPoolAllowed(uint256 poolId) external view returns (bool) {
        return LibAmmSkillStorage.layout().allowedPools[poolId];
    }

    function getAuctionPolicy() external view returns (LibAmmSkillStorage.AuctionPolicy memory) {
        return LibAmmSkillStorage.layout().auctionPolicy;
    }

    function getRollPolicy() external view returns (LibAmmSkillStorage.RollPolicy memory) {
        return LibAmmSkillStorage.layout().rollPolicy;
    }

    function getDiamond() external view returns (address) {
        return LibAmmSkillStorage.layout().diamond;
    }

    function _requireOwner() internal view {
        address owner = IERC6551Account(address(this)).owner();
        if (msg.sender != owner) {
            revert AmmSkill_Unauthorized(msg.sender);
        }
    }

    function _enforceAuctionPolicy(
        LibAmmSkillStorage.Layout storage ds,
        DerivativeTypes.CreateAuctionParams calldata params
    ) internal view {
        LibAmmSkillStorage.AuctionPolicy memory policy = ds.auctionPolicy;
        if (!policy.enabled) {
            revert AmmSkill_PolicyDisabled();
        }
        if (policy.enforcePoolAllowlist) {
            if (!ds.allowedPools[params.poolIdA]) {
                revert AmmSkill_PoolNotAllowed(params.poolIdA);
            }
            if (!ds.allowedPools[params.poolIdB]) {
                revert AmmSkill_PoolNotAllowed(params.poolIdB);
            }
        }
        if (params.endTime < params.startTime) {
            revert AmmSkill_DurationOutOfBounds(0, policy.minDuration, policy.maxDuration);
        }
        uint64 duration = params.endTime - params.startTime;
        if (policy.minDuration != 0 && duration < policy.minDuration) {
            revert AmmSkill_DurationOutOfBounds(duration, policy.minDuration, policy.maxDuration);
        }
        if (policy.maxDuration != 0 && duration > policy.maxDuration) {
            revert AmmSkill_DurationOutOfBounds(duration, policy.minDuration, policy.maxDuration);
        }
        if (policy.minFeeBps != 0 && params.feeBps < policy.minFeeBps) {
            revert AmmSkill_FeeOutOfBounds(params.feeBps, policy.minFeeBps, policy.maxFeeBps);
        }
        if (policy.maxFeeBps != 0 && params.feeBps > policy.maxFeeBps) {
            revert AmmSkill_FeeOutOfBounds(params.feeBps, policy.minFeeBps, policy.maxFeeBps);
        }
        if (policy.minReserveA != 0 && params.reserveA < policy.minReserveA) {
            revert AmmSkill_ReserveOutOfBounds(params.reserveA, policy.minReserveA, policy.maxReserveA);
        }
        if (policy.maxReserveA != 0 && params.reserveA > policy.maxReserveA) {
            revert AmmSkill_ReserveOutOfBounds(params.reserveA, policy.minReserveA, policy.maxReserveA);
        }
        if (policy.minReserveB != 0 && params.reserveB < policy.minReserveB) {
            revert AmmSkill_ReserveOutOfBounds(params.reserveB, policy.minReserveB, policy.maxReserveB);
        }
        if (policy.maxReserveB != 0 && params.reserveB > policy.maxReserveB) {
            revert AmmSkill_ReserveOutOfBounds(params.reserveB, policy.minReserveB, policy.maxReserveB);
        }
    }

    function _enforceRollPolicy(LibAmmSkillStorage.Layout storage ds, uint256 pid) internal view {
        LibAmmSkillStorage.RollPolicy memory policy = ds.rollPolicy;
        if (!policy.enabled) {
            revert AmmSkill_PolicyDisabled();
        }
        if (policy.enforcePoolAllowlist && !ds.allowedPools[pid]) {
            revert AmmSkill_PoolNotAllowed(pid);
        }
    }
}
