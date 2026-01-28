// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {EnhancedLoanViewFacet} from "../src/views/EnhancedLoanViewFacet.sol";
import {PoolUtilizationViewFacet} from "../src/views/PoolUtilizationViewFacet.sol";
import {LoanPreviewFacet} from "../src/views/LoanPreviewFacet.sol";

/// @notice Verification script to check that all new view facets are properly deployed
contract VerifyViewFacetsScript is Script {
    function run() external view {
        address diamondAddress = vm.envAddress("DIAMOND_ADDRESS");
        
        console2.log("=== Verifying View Facets ===");
        console2.log("Diamond Address:", diamondAddress);
        console2.log("");

        IDiamondLoupe loupe = IDiamondLoupe(diamondAddress);
        
        // Get all facets
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        console2.log("Total Facets:", facets.length);
        console2.log("");

        // Check for our new facets
        bool foundEnhanced = false;
        bool foundPoolUtil = false;
        bool foundLoanPreview = false;

        for (uint256 i = 0; i < facets.length; i++) {
            bytes4[] memory selectors = facets[i].functionSelectors;
            
            // Check if this facet has our functions
            for (uint256 j = 0; j < selectors.length; j++) {
                if (selectors[j] == EnhancedLoanViewFacet.getUserLoanSummary.selector) {
                    foundEnhanced = true;
                    console2.log("[OK] EnhancedLoanViewFacet found at:", facets[i].facetAddress);
                    console2.log("   Functions:", selectors.length);
                }
                if (selectors[j] == PoolUtilizationViewFacet.getPoolUtilization.selector) {
                    foundPoolUtil = true;
                    console2.log("[OK] PoolUtilizationViewFacet found at:", facets[i].facetAddress);
                    console2.log("   Functions:", selectors.length);
                }
                if (selectors[j] == LoanPreviewFacet.previewFixedLoanCosts.selector) {
                    foundLoanPreview = true;
                    console2.log("[OK] LoanPreviewFacet found at:", facets[i].facetAddress);
                    console2.log("   Functions:", selectors.length);
                }
            }
        }

        console2.log("");
        console2.log("=== Verification Results ===");
        
        if (foundEnhanced && foundPoolUtil && foundLoanPreview) {
            console2.log("[OK] All new view facets deployed successfully!");
        } else {
            console2.log("[ERROR] Some facets missing:");
            if (!foundEnhanced) console2.log("   - EnhancedLoanViewFacet");
            if (!foundPoolUtil) console2.log("   - PoolUtilizationViewFacet");
            if (!foundLoanPreview) console2.log("   - LoanPreviewFacet");
        }

        // List all function selectors for new facets
        console2.log("");
        console2.log("=== Expected Function Selectors ===");
        
        console2.log("EnhancedLoanViewFacet (8 functions):");
        console2.log("  getUserLoanSummary:", vm.toString(EnhancedLoanViewFacet.getUserLoanSummary.selector));
        console2.log("  getUserFixedLoansDetailed:", vm.toString(EnhancedLoanViewFacet.getUserFixedLoansDetailed.selector));
        console2.log("  getUserFixedLoansPaginated:", vm.toString(EnhancedLoanViewFacet.getUserFixedLoansPaginated.selector));
        console2.log("  getUserHealthMetrics:", vm.toString(EnhancedLoanViewFacet.getUserHealthMetrics.selector));
        console2.log("  previewBorrowFixed:", vm.toString(EnhancedLoanViewFacet.previewBorrowFixed.selector));
        console2.log("  canOpenFixedLoan:", vm.toString(EnhancedLoanViewFacet.canOpenFixedLoan.selector));
        console2.log("  getFixedLoanAccrued:", vm.toString(EnhancedLoanViewFacet.getFixedLoanAccrued.selector));
        console2.log("  previewRepayFixed:", vm.toString(EnhancedLoanViewFacet.previewRepayFixed.selector));
        
        console2.log("");
        console2.log("PoolUtilizationViewFacet (4 functions):");
        console2.log("  getPoolUtilization:", vm.toString(PoolUtilizationViewFacet.getPoolUtilization.selector));
        console2.log("  canDeposit:", vm.toString(PoolUtilizationViewFacet.canDeposit.selector));
        console2.log("  getPoolCapacity:", vm.toString(PoolUtilizationViewFacet.getPoolCapacity.selector));
        console2.log("  getAvailableLiquidity:", vm.toString(PoolUtilizationViewFacet.getAvailableLiquidity.selector));
        
        console2.log("");
        console2.log("LoanPreviewFacet (5 functions):");
        console2.log("  previewFixedLoanCosts:", vm.toString(LoanPreviewFacet.previewFixedLoanCosts.selector));
        console2.log("  previewRollingLoanCosts:", vm.toString(LoanPreviewFacet.previewRollingLoanCosts.selector));
        console2.log("  calculateFixedLoanPayoff:", vm.toString(LoanPreviewFacet.calculateFixedLoanPayoff.selector));
        console2.log("  calculateRollingLoanPayoff:", vm.toString(LoanPreviewFacet.calculateRollingLoanPayoff.selector));
        console2.log("  previewFixedRepaymentImpact:", vm.toString(LoanPreviewFacet.previewFixedRepaymentImpact.selector));
    }
}
