// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EqualIndexAdminFacetV3} from "./EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "./EqualIndexActionsFacetV3.sol";
import {EqualIndexViewFacetV3} from "../views/EqualIndexViewFacetV3.sol";

/// @notice Backwards-compatible composite exposing all EqualIndex V3 selectors.
/// @dev Useful for local testing; production deployments should compose the slim facets directly.
contract EqualIndexFacetV3 is EqualIndexAdminFacetV3, EqualIndexActionsFacetV3, EqualIndexViewFacetV3 {}
