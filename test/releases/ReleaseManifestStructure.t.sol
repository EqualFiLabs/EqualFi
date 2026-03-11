// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FacetId} from "../../script/releases/ManifestTypes.sol";
import {ReleaseV1Manifest} from "../../script/releases/manifests/ReleaseV1.sol";
import {ReleaseV2Manifest} from "../../script/releases/manifests/ReleaseV2.sol";
import {ReleaseV3Manifest} from "../../script/releases/manifests/ReleaseV3.sol";
import {ReleaseV4Manifest} from "../../script/releases/manifests/ReleaseV4.sol";
import {ReleaseV5Manifest} from "../../script/releases/manifests/ReleaseV5.sol";

contract ReleaseManifestStructureTest is Test {
    ReleaseV1Manifest internal v1;
    ReleaseV2Manifest internal v2;
    ReleaseV3Manifest internal v3;
    ReleaseV4Manifest internal v4;
    ReleaseV5Manifest internal v5;

    function setUp() public {
        v1 = new ReleaseV1Manifest();
        v2 = new ReleaseV2Manifest();
        v3 = new ReleaseV3Manifest();
        v4 = new ReleaseV4Manifest();
        v5 = new ReleaseV5Manifest();
    }

    function testReleaseManifestsRemainCumulativeAndDuplicateFree() public {
        FacetId[] memory v1Ids = v1.facetIds();
        FacetId[] memory v2Ids = v2.facetIds();
        FacetId[] memory v3Ids = v3.facetIds();
        FacetId[] memory v4Ids = v4.facetIds();
        FacetId[] memory v5Ids = v5.facetIds();

        assertEq(v1Ids.length, 42);
        assertEq(v2Ids.length, 52);
        assertEq(v3Ids.length, 56);
        assertEq(v4Ids.length, 60);
        assertEq(v5Ids.length, 64);

        _assertPrefix(v1Ids, v2Ids);
        _assertPrefix(v2Ids, v3Ids);
        _assertPrefix(v3Ids, v4Ids);
        _assertPrefix(v4Ids, v5Ids);

        _assertNoDuplicates(v1Ids);
        _assertNoDuplicates(v2Ids);
        _assertNoDuplicates(v3Ids);
        _assertNoDuplicates(v4Ids);
        _assertNoDuplicates(v5Ids);
    }

    function _assertPrefix(FacetId[] memory expectedPrefix, FacetId[] memory full) internal {
        for (uint256 i; i < expectedPrefix.length; ++i) {
            assertEq(uint256(expectedPrefix[i]), uint256(full[i]), "manifest prefix mismatch");
        }
    }

    function _assertNoDuplicates(FacetId[] memory ids) internal {
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                assertTrue(ids[i] != ids[j], "duplicate facet id");
            }
        }
    }
}
