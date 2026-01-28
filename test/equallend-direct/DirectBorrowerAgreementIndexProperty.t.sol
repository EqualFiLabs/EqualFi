// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

contract BorrowerAgreementIndexHarness is DirectDiamondTestBase {
    constructor() {
        setUpDiamond();
    }

    function add(bytes32 borrowerKey, uint256 agreementId) external {
        harness.addBorrowerAgreement(borrowerKey, agreementId);
    }

    function remove(bytes32 borrowerKey, uint256 agreementId) external {
        harness.removeBorrowerAgreement(borrowerKey, agreementId);
    }

    function page(bytes32 borrowerKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory agreements, uint256 total)
    {
        return views.borrowerAgreementsPage(borrowerKey, offset, limit);
    }

    function list(bytes32 borrowerKey) external view returns (uint256[] memory agreements) {
        (agreements,) = views.borrowerAgreementsPage(borrowerKey, 0, 0);
    }

    function indexOf(bytes32 borrowerKey, uint256 agreementId) external view returns (bool exists, uint256 idx) {
        (uint256[] memory agreements,) = views.borrowerAgreementsPage(borrowerKey, 0, 0);
        for (uint256 i; i < agreements.length; i++) {
            if (agreements[i] == agreementId) {
                exists = true;
                idx = i;
                break;
            }
        }
    }
}

/// @notice Feature: multi-pool-position-nfts, Property 3: Borrower Agreement Index Consistency
/// @notice Feature: multi-pool-position-nfts, Property 8: Borrower Agreement Processing Determinism
/// @notice Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 6.5, 6.7
/// forge-config: default.fuzz.runs = 100
contract DirectBorrowerAgreementIndexPropertyTest is DirectDiamondTestBase {
    BorrowerAgreementIndexHarness internal indexHarness;
    bytes32 internal constant BORROWER_KEY = keccak256("BORROWER_KEY");

    function setUp() public {
        indexHarness = new BorrowerAgreementIndexHarness();
    }

    function testProperty_BorrowerAgreementIndexConsistency(
        uint256[] memory agreementIds,
        uint256[] memory removalSelectors,
        uint256 offset,
        uint256 limit
    ) public {
        uint256 maxOps = 20;
        uint256[] memory expected = new uint256[](maxOps);
        uint256 expectedLen;

        uint256 addCount = agreementIds.length < maxOps ? agreementIds.length : maxOps;
        for (uint256 i; i < addCount; i++) {
            uint256 id = bound(agreementIds[i], 1, type(uint128).max);
            if (_contains(expected, expectedLen, id)) continue;
            indexHarness.add(BORROWER_KEY, id);
            expected[expectedLen++] = id;
            _assertAlignment(expected, expectedLen);
        }

        uint256 removeCount = removalSelectors.length < maxOps ? removalSelectors.length : maxOps;
        for (uint256 i; i < removeCount; i++) {
            if (expectedLen == 0) break;
            uint256 idx = removalSelectors[i] % expectedLen;
            uint256 idToRemove = expected[idx];
            indexHarness.remove(BORROWER_KEY, idToRemove);
            // Order-preserving removal
            for (uint256 j = idx; j + 1 < expectedLen; j++) {
                expected[j] = expected[j + 1];
            }
            expectedLen -= 1;
            _assertAlignment(expected, expectedLen);
        }

        offset = expectedLen == 0 ? 0 : bound(offset, 0, expectedLen);
        limit = bound(limit, 0, expectedLen + 2);

        (uint256[] memory page, uint256 total) = indexHarness.page(BORROWER_KEY, offset, limit);
        assertEq(total, expectedLen, "total count matches");

        uint256 expectedPageLen = offset >= expectedLen
            ? 0
            : (limit == 0 || limit > expectedLen - offset ? expectedLen - offset : limit);
        assertEq(page.length, expectedPageLen, "page length matches expected");

        for (uint256 i; i < expectedPageLen; i++) {
            assertEq(page[i], expected[offset + i], "page entry matches expected ordering");
        }
    }

    function testProperty_BorrowerAgreementProcessingDeterminism(
        uint256[] memory agreementIds,
        uint256[] memory removalSelectors,
        uint256 offset,
        uint256 limit
    ) public {
        BorrowerAgreementIndexHarness harnessA = new BorrowerAgreementIndexHarness();
        BorrowerAgreementIndexHarness harnessB = new BorrowerAgreementIndexHarness();

        (uint256[] memory expected, uint256 expectedLen) =
            _applySequence(harnessA, harnessB, agreementIds, removalSelectors);

        uint256[] memory listA = harnessA.list(BORROWER_KEY);
        uint256[] memory listB = harnessB.list(BORROWER_KEY);
        assertEq(listA.length, expectedLen, "harnessA list length");
        assertEq(listB.length, expectedLen, "harnessB list length");

        for (uint256 i; i < expectedLen; i++) {
            assertEq(listA[i], expected[i], "harnessA ordering");
            assertEq(listB[i], expected[i], "harnessB ordering");
        }

        offset = expectedLen == 0 ? 0 : bound(offset, 0, expectedLen);
        limit = bound(limit, 0, expectedLen + 3);

        (uint256[] memory pageA, uint256 totalA) = harnessA.page(BORROWER_KEY, offset, limit);
        (uint256[] memory pageB, uint256 totalB) = harnessB.page(BORROWER_KEY, offset, limit);
        assertEq(totalA, expectedLen, "harnessA total");
        assertEq(totalB, expectedLen, "harnessB total");
        assertEq(pageA.length, pageB.length, "page lengths align");

        uint256 expectedPageLen = offset >= expectedLen
            ? 0
            : (limit == 0 || limit > expectedLen - offset ? expectedLen - offset : limit);
        assertEq(pageA.length, expectedPageLen, "page length matches expected");

        for (uint256 i; i < expectedPageLen; i++) {
            assertEq(pageA[i], expected[offset + i], "harnessA page ordering");
            assertEq(pageB[i], expected[offset + i], "harnessB page ordering");
        }
    }

    function _applySequence(
        BorrowerAgreementIndexHarness harnessA,
        BorrowerAgreementIndexHarness harnessB,
        uint256[] memory agreementIds,
        uint256[] memory removalSelectors
    ) internal returns (uint256[] memory expected, uint256 expectedLen) {
        uint256 maxOps = 15;
        expected = new uint256[](maxOps);
        uint256 addCount = agreementIds.length < maxOps ? agreementIds.length : maxOps;
        for (uint256 i; i < addCount; i++) {
            uint256 id = bound(agreementIds[i], 1, type(uint128).max);
            if (_contains(expected, expectedLen, id)) continue;
            harnessA.add(BORROWER_KEY, id);
            harnessB.add(BORROWER_KEY, id);
            expected[expectedLen++] = id;
        }

        uint256 removeCount = removalSelectors.length < maxOps ? removalSelectors.length : maxOps;
        for (uint256 i; i < removeCount; i++) {
            if (expectedLen == 0) break;
            uint256 idx = removalSelectors[i] % expectedLen;
            uint256 idToRemove = expected[idx];
            harnessA.remove(BORROWER_KEY, idToRemove);
            harnessB.remove(BORROWER_KEY, idToRemove);
            for (uint256 j = idx; j + 1 < expectedLen; j++) {
                expected[j] = expected[j + 1];
            }
            expectedLen -= 1;
        }
    }

    function _assertAlignment(uint256[] memory expected, uint256 expectedLen) internal {
        uint256[] memory stored = indexHarness.list(BORROWER_KEY);
        assertEq(stored.length, expectedLen, "stored length matches expected");
        for (uint256 i; i < expectedLen; i++) {
            assertEq(stored[i], expected[i], "stored ordering matches");
            (bool exists, uint256 idx) = indexHarness.indexOf(BORROWER_KEY, expected[i]);
            assertTrue(exists, "index entry exists");
            assertEq(idx, i, "index matches position");
        }
    }

    function _contains(uint256[] memory arr, uint256 length, uint256 value) internal pure returns (bool) {
        for (uint256 i; i < length; i++) {
            if (arr[i] == value) return true;
        }
        return false;
    }
}
