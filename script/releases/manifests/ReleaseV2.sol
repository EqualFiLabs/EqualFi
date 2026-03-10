// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FacetId, IReleaseManifest} from "../ManifestTypes.sol";
import {ReleaseStages} from "../ReleaseStages.sol";

contract ReleaseV2Manifest is IReleaseManifest, ReleaseStages {
    function name() external pure returns (string memory) {
        return "v2";
    }

    function facetIds() external pure returns (FacetId[] memory ids) {
        ids = _concat(_v1Base(), _v2Direct());
    }
}
