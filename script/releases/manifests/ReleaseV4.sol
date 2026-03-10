// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FacetId, IReleaseManifest} from "../ManifestTypes.sol";
import {ReleaseStages} from "../ReleaseStages.sol";

contract ReleaseV4Manifest is IReleaseManifest, ReleaseStages {
    function name() external pure returns (string memory) {
        return "v4";
    }

    function facetIds() external pure returns (FacetId[] memory ids) {
        ids = _concat(_concat(_concat(_v1Base(), _v2Direct()), _v3IlmIsolated()), _v4IlmPooled());
    }
}
