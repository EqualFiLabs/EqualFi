// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "../libraries/Types.sol";

interface IActiveCreditViewFacet {
    struct ActiveCreditStatus {
        uint256 encumbrancePrincipal;
        uint256 debtPrincipal;
        uint256 encumbranceTimeCredit;
        uint256 debtTimeCredit;
        bool encumbranceMature;
        bool debtMature;
        uint256 encumbranceActiveWeight;
        uint256 debtActiveWeight;
    }

    function getActiveCreditStates(uint256 pid, bytes32 user)
        external
        view
        returns (Types.ActiveCreditState memory encumbrance, Types.ActiveCreditState memory debt);

    function getActiveCreditStatesByPosition(uint256 pid, uint256 positionId)
        external
        view
        returns (Types.ActiveCreditState memory encumbrance, Types.ActiveCreditState memory debt);

    function getActiveCreditStatus(uint256 pid, bytes32 user) external view returns (ActiveCreditStatus memory status);

    function getActiveCreditStatusByPosition(uint256 pid, uint256 positionId)
        external
        view
        returns (ActiveCreditStatus memory status);

    function pendingActiveCredit(uint256 pid, bytes32 user) external view returns (uint256);

    function pendingActiveCreditByPosition(uint256 pid, uint256 positionId) external view returns (uint256);

    function getActiveCreditIndex(uint256 pid)
        external
        view
        returns (uint256 index, uint256 remainder, uint256 activePrincipalTotal);
}
