// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MamTypes} from "../libraries/MamTypes.sol";

/// @notice MAM curve interface composed across multiple facets.
interface MamCurveFacet {
    function setMamPaused(bool paused) external;

    function createCurve(MamTypes.CurveDescriptor calldata desc) external returns (uint256 curveId);

    function createCurvesBatch(MamTypes.CurveDescriptor[] calldata descs)
        external
        returns (uint256 firstCurveId);

    function updateCurve(uint256 curveId, MamTypes.CurveUpdateParams calldata params) external;

    function updateCurvesBatch(uint256[] calldata curveIds, MamTypes.CurveUpdateParams[] calldata params) external;

    function cancelCurve(uint256 curveId) external;

    function cancelCurvesBatch(uint256[] calldata curveIds) external;

    function expireCurve(uint256 curveId) external;

    function expireCurvesBatch(uint256[] calldata curveIds) external;

    function loadCurveForFill(uint256 curveId)
        external
        view
        returns (MamTypes.CurveFillView memory viewData);

    function executeCurveSwap(
        uint256 curveId,
        uint256 amountIn,
        uint256 minOut,
        uint64 deadline,
        address recipient
    ) external payable returns (uint256 amountOut);
}
