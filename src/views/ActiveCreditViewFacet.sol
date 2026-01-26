// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {IActiveCreditViewFacet} from "../interfaces/IActiveCreditViewFacet.sol";

/// @notice Read-only views for Active Credit index state and eligibility
contract ActiveCreditViewFacet is IActiveCreditViewFacet {
    using LibActiveCreditIndex for Types.ActiveCreditState;

    function getActiveCreditStates(uint256 pid, bytes32 user)
        external
        view
        returns (Types.ActiveCreditState memory encumbrance, Types.ActiveCreditState memory debt)
    {
        Types.PoolData storage p = _pool(pid);
        encumbrance = p.userActiveCreditStateEncumbrance[user];
        debt = p.userActiveCreditStateDebt[user];
    }

    function getActiveCreditStatesByPosition(uint256 pid, uint256 positionId)
        external
        view
        returns (Types.ActiveCreditState memory encumbrance, Types.ActiveCreditState memory debt)
    {
        bytes32 positionKey = _positionKey(positionId);
        Types.PoolData storage p = _pool(pid);
        encumbrance = p.userActiveCreditStateEncumbrance[positionKey];
        debt = p.userActiveCreditStateDebt[positionKey];
    }

    function getActiveCreditStatus(uint256 pid, bytes32 user)
        external
        view
        returns (ActiveCreditStatus memory status)
    {
        Types.PoolData storage p = _pool(pid);
        Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
        Types.ActiveCreditState storage debt = p.userActiveCreditStateDebt[user];
        status.encumbrancePrincipal = enc.principal;
        status.debtPrincipal = debt.principal;
        status.encumbranceTimeCredit = enc.timeCredit();
        status.debtTimeCredit = debt.timeCredit();
        status.encumbranceMature = status.encumbranceTimeCredit >= LibActiveCreditIndex.TIME_GATE && enc.principal > 0;
        status.debtMature = status.debtTimeCredit >= LibActiveCreditIndex.TIME_GATE && debt.principal > 0;
        status.encumbranceActiveWeight = enc.activeWeight();
        status.debtActiveWeight = debt.activeWeight();
    }

    function getActiveCreditStatusByPosition(uint256 pid, uint256 positionId)
        external
        view
        returns (ActiveCreditStatus memory status)
    {
        bytes32 positionKey = _positionKey(positionId);
        Types.PoolData storage p = _pool(pid);
        Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[positionKey];
        Types.ActiveCreditState storage debt = p.userActiveCreditStateDebt[positionKey];
        status.encumbrancePrincipal = enc.principal;
        status.debtPrincipal = debt.principal;
        status.encumbranceTimeCredit = enc.timeCredit();
        status.debtTimeCredit = debt.timeCredit();
        status.encumbranceMature = status.encumbranceTimeCredit >= LibActiveCreditIndex.TIME_GATE && enc.principal > 0;
        status.debtMature = status.debtTimeCredit >= LibActiveCreditIndex.TIME_GATE && debt.principal > 0;
        status.encumbranceActiveWeight = enc.activeWeight();
        status.debtActiveWeight = debt.activeWeight();
    }

    function pendingActiveCredit(uint256 pid, bytes32 user) external view returns (uint256) {
        _pool(pid);
        return LibActiveCreditIndex.pendingActiveCredit(pid, user);
    }

    function pendingActiveCreditByPosition(uint256 pid, uint256 positionId) external view returns (uint256) {
        bytes32 positionKey = _positionKey(positionId);
        _pool(pid);
        return LibActiveCreditIndex.pendingActiveCredit(pid, positionKey);
    }

    function getActiveCreditIndex(uint256 pid)
        external
        view
        returns (uint256 index, uint256 remainder, uint256 activePrincipalTotal)
    {
        Types.PoolData storage p = _pool(pid);
        return (p.activeCreditIndex, p.activeCreditIndexRemainder, p.activeCreditPrincipalTotal);
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](7);
        selectorsArr[0] = ActiveCreditViewFacet.getActiveCreditStates.selector;
        selectorsArr[1] = ActiveCreditViewFacet.getActiveCreditStatesByPosition.selector;
        selectorsArr[2] = ActiveCreditViewFacet.getActiveCreditStatus.selector;
        selectorsArr[3] = ActiveCreditViewFacet.getActiveCreditStatusByPosition.selector;
        selectorsArr[4] = ActiveCreditViewFacet.pendingActiveCredit.selector;
        selectorsArr[5] = ActiveCreditViewFacet.pendingActiveCreditByPosition.selector;
        selectorsArr[6] = ActiveCreditViewFacet.getActiveCreditIndex.selector;
    }

    function _positionKey(uint256 positionId) private view returns (bytes32) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        require(ns.nftModeEnabled && ns.positionNFTContract != address(0), "ActiveCreditView: position NFT disabled");
        PositionNFT nft = PositionNFT(ns.positionNFTContract);
        return nft.getPositionKey(positionId);
    }

    function _pool(uint256 pid) private view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "ActiveCreditView: uninit pool");
        return p;
    }
}
