// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibPositionList} from "../libraries/LibPositionList.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";

/// @title MultiPoolPositionViewFacet
/// @notice View functions for querying Position NFT state across multiple pools
/// @dev Provides efficient aggregation of position data from multiple pools
contract MultiPoolPositionViewFacet {
    
    /// @notice Multi-pool position state data
    struct MultiPoolPositionState {
        uint256 tokenId;
        bytes32 positionKey;
        PoolPositionData[] pools;
        DirectAgreementSummary directState;
    }

    /// @notice Position data for a specific pool
    struct PoolPositionData {
        uint256 poolId;
        address underlying;
        uint256 principal;
        uint256 yield;
        bool hasActiveLoan;
        uint256 totalDebt;
        bool isMember;
    }

    /// @notice Summary of direct agreement state
    struct DirectAgreementSummary {
        uint256 totalLocked;
        uint256 totalLent;
        uint256 totalBorrowed;
        uint256 activeAgreementCount;
    }

    struct DirectAssetSummary {
        address asset;
        uint256 lent;
        uint256 locked;
        uint256 borrowed;
    }

    struct PositionDirectAgreement {
        DirectTypes.DirectAgreement agreement;
        bool isBorrower;
        bool isLender;
    }

    struct PositionOwnerSummary {
        uint256 tokenId;
        bytes32 positionKey;
    }

    /// @notice Pool membership information
    struct PoolMembershipInfo {
        uint256 poolId;
        address underlying;
        bool isMember;
        bool hasBalance;
        bool hasActiveLoans;
    }

    /// @notice Get the app storage
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    /// @notice Get a pool by ID with validation
    /// @param pid The pool ID
    /// @return The pool data storage reference
    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = s().pools[pid];
        require(p.initialized, "MultiPoolPositionView: pool not initialized");
        return p;
    }

    /// @notice Get the position key for a token ID
    /// @param tokenId The token ID
    /// @return The position key (bytes32 used in PoolData mappings)
    function _getPositionKey(uint256 tokenId) internal view returns (bytes32) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        return nft.getPositionKey(tokenId);
    }

    /// @notice Calculate pool-specific debt for a position (excludes direct agreements)
    /// @param p The pool data storage reference
    /// @param positionKey The position key
    /// @return poolDebt The pool-specific debt (rolling + fixed-term only)
    function _calculatePoolDebt(
        Types.PoolData storage p,
        bytes32 positionKey
    ) internal view returns (uint256 poolDebt) {
        // Rolling loan debt
        Types.RollingCreditLoan storage rolling = p.rollingLoans[positionKey];
        if (rolling.active) {
            poolDebt += rolling.principalRemaining;
        }

        // Fixed-term loan debt
        uint256[] storage loanIds = p.userFixedLoanIds[positionKey];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                poolDebt += loan.principalRemaining;
            }
        }
    }

    /// @notice Calculate total debt for a position including direct agreements
    /// @param p The pool data storage reference
    /// @param positionKey The position key
    /// @return totalDebt The total debt (rolling + fixed-term + direct)
    function _calculateTotalPoolDebt(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid
    ) internal view returns (uint256 totalDebt) {
        totalDebt = _calculatePoolDebt(p, positionKey);
        
        // Direct agreement borrower debt for this pool
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        totalDebt += ds.directBorrowedPrincipal[positionKey][pid];
    }

    /// @notice Check if a position has active loans in a specific pool
    /// @param p The pool data storage reference
    /// @param positionKey The position key
    /// @return hasActiveLoans True if the position has active pool-specific loans
    function _hasActiveLoans(
        Types.PoolData storage p,
        bytes32 positionKey
    ) internal view returns (bool hasActiveLoans) {
        // Check rolling loan
        Types.RollingCreditLoan storage rolling = p.rollingLoans[positionKey];
        if (rolling.active && rolling.principalRemaining > 0) {
            return true;
        }

        // Check fixed-term loans
        if (p.activeFixedLoanCount[positionKey] > 0) {
            return true;
        }

        return false;
    }

    /// @notice Check if a position has any active loans (pool-specific + direct agreements)
    /// @param positionKey The position key
    /// @return hasActiveLoans True if the position has any active loans
    function _hasAnyActiveLoans(bytes32 positionKey) internal view returns (bool hasActiveLoans) {
        // Check all pools for active loans or direct agreements
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibAppStorage.AppStorage storage store = s();
        uint256 poolCount = store.poolCount;
        
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
            if (ds.directBorrowedPrincipal[positionKey][pid] > 0 || enc.directLent > 0) {
                return true;
            }
            if (_hasActiveLoans(p, positionKey)) {
                return true;
            }
        }

        return false;
    }

    /// @notice Get complete multi-pool position state for a Position NFT
    /// @param tokenId The token ID
    /// @return state The multi-pool position state
    function getMultiPoolPositionState(uint256 tokenId) 
        external 
        view 
        returns (MultiPoolPositionState memory state) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        LibAppStorage.AppStorage storage store = s();
        
        state.tokenId = tokenId;
        state.positionKey = positionKey;

        // Get direct agreement summary
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256 totalLocked = 0;
        uint256 totalLent = 0;
        uint256 totalBorrowed = 0;
        uint256 poolCount = store.poolCount;
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage pool = store.pools[pid];
            if (!pool.initialized) continue;
            LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
            totalLocked += enc.directLocked;
            totalLent += enc.directLent + enc.directOfferEscrow;
            totalBorrowed += ds.directBorrowedPrincipal[positionKey][pid];
        }

        (,, uint256 activeAgreements) = LibPositionList.meta(ds.borrowerAgreements, positionKey);
        state.directState = DirectAgreementSummary({
            totalLocked: totalLocked,
            totalLent: totalLent,
            totalBorrowed: totalBorrowed,
            activeAgreementCount: activeAgreements
        });

        // Count pools with membership or balances
        uint256 relevantPoolCount = 0;
        poolCount = store.poolCount;
        
        // First pass: count relevant pools
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            
            if (isMember || hasBalance || hasLoans) {
                relevantPoolCount++;
            }
        }

        state.pools = new PoolPositionData[](relevantPoolCount);
        uint256 poolIndex = 0;

        // Second pass: populate pool data
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            
            if (isMember || hasBalance || hasLoans) {
                uint256 principal = p.userPrincipal[positionKey];
                uint256 yield = LibFeeIndex.pendingYield(pid, positionKey);
                uint256 totalDebt = _calculateTotalPoolDebt(p, positionKey, pid);
                
                state.pools[poolIndex] = PoolPositionData({
                    poolId: pid,
                    underlying: p.underlying,
                    principal: principal,
                    yield: yield,
                    hasActiveLoan: hasLoans,
                    totalDebt: totalDebt,
                    isMember: isMember
                });
                poolIndex++;
            }
        }
    }

    /// @notice Get pool membership information for a Position NFT across all pools
    /// @param tokenId The token ID
    /// @return memberships Array of pool membership information
    function getPositionPoolMemberships(uint256 tokenId) 
        external 
        view 
        returns (PoolMembershipInfo[] memory memberships) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        LibAppStorage.AppStorage storage store = s();
        uint256 poolCount = store.poolCount;
        
        // Count initialized pools
        uint256 initializedPoolCount = 0;
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            if (store.pools[pid].initialized) {
                initializedPoolCount++;
            }
        }

        memberships = new PoolMembershipInfo[](initializedPoolCount);
        uint256 membershipIndex = 0;

        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasActiveLoans = _hasActiveLoans(p, positionKey);
            
            memberships[membershipIndex] = PoolMembershipInfo({
                poolId: pid,
                underlying: p.underlying,
                isMember: isMember,
                hasBalance: hasBalance,
                hasActiveLoans: hasActiveLoans
            });
            membershipIndex++;
        }
    }

    /// @notice Get position data for a specific pool
    /// @param tokenId The token ID
    /// @param pid The pool ID
    /// @return poolData The position data for the specified pool
    function getPositionPoolData(uint256 tokenId, uint256 pid) 
        external 
        view 
        returns (PoolPositionData memory poolData) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        Types.PoolData storage p = _pool(pid);
        
        bool isMember = LibPoolMembership.isMember(positionKey, pid);
        uint256 principal = p.userPrincipal[positionKey];
        uint256 yield = LibFeeIndex.pendingYield(pid, positionKey);
        uint256 totalDebt = _calculateTotalPoolDebt(p, positionKey, pid);
        bool hasActiveLoans = _hasActiveLoans(p, positionKey);
        
        poolData = PoolPositionData({
            poolId: pid,
            underlying: p.underlying,
            principal: principal,
            yield: yield,
            hasActiveLoan: hasActiveLoans,
            totalDebt: totalDebt,
            isMember: isMember
        });
    }

    /// @notice Check if a Position NFT is a member of a specific pool
    /// @param tokenId The token ID
    /// @param pid The pool ID
    /// @return isMember True if the position is a member of the pool
    function isPositionMemberOfPool(uint256 tokenId, uint256 pid) 
        external 
        view 
        returns (bool isMember) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        return LibPoolMembership.isMember(positionKey, pid);
    }

    /// @notice Get aggregated position summary across all pools
    /// @param tokenId The token ID
    /// @return totalPrincipal Total principal across all pools
    /// @return totalYield Total pending yield across all pools
    /// @return totalDebt Total debt across all pools
    /// @return poolCount Number of pools with membership or balances
    /// @return directSummary Direct agreement summary
    function getPositionAggregatedSummary(uint256 tokenId) 
        external 
        view 
        returns (
            uint256 totalPrincipal,
            uint256 totalYield,
            uint256 totalDebt,
            uint256 poolCount,
            DirectAgreementSummary memory directSummary
        ) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        LibAppStorage.AppStorage storage store = s();
        uint256 maxPoolId = store.poolCount;
        
        // Get direct agreement summary
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256 totalLocked = 0;
        uint256 totalLent = 0;
        uint256 totalBorrowed = 0;
        for (uint256 pid = 1; pid <= maxPoolId; pid++) {
            Types.PoolData storage pool = store.pools[pid];
            if (!pool.initialized) continue;
            LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
            totalLocked += enc.directLocked;
            totalLent += enc.directLent + enc.directOfferEscrow;
            totalBorrowed += ds.directBorrowedPrincipal[positionKey][pid];
        }
        (,, uint256 activeAgreements) = LibPositionList.meta(ds.borrowerAgreements, positionKey);
        directSummary = DirectAgreementSummary({
            totalLocked: totalLocked,
            totalLent: totalLent,
            totalBorrowed: totalBorrowed,
            activeAgreementCount: activeAgreements
        });

        // Check if position has any direct agreements (global)
        bool hasDirectAgreements = directSummary.totalLocked > 0 || 
                                  directSummary.totalLent > 0 || 
                                  directSummary.totalBorrowed > 0;

        // Aggregate across all pools
        for (uint256 pid = 1; pid <= maxPoolId; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            
            // Include pool if it has membership, balance, loans, or if position has direct agreements
            if (isMember || hasBalance || hasLoans || hasDirectAgreements) {
                poolCount++;
                totalPrincipal += p.userPrincipal[positionKey];
                totalYield += LibFeeIndex.pendingYield(pid, positionKey);
                totalDebt += _calculatePoolDebt(p, positionKey); // Pool-specific debt only
            }
        }
        
        // Add direct agreement borrower debt once (global, not per-pool)
        totalDebt += directSummary.totalBorrowed;
    }

    /// @notice Get pools where a Position NFT has active participation
    /// @param tokenId The token ID
    /// @return activePoolIds Array of pool IDs where the position has membership, balances, or loans
    function getPositionActivePools(uint256 tokenId) 
        external 
        view 
        returns (uint256[] memory activePoolIds) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        LibAppStorage.AppStorage storage store = s();
        uint256 poolCount = store.poolCount;
        
        // Count active pools
        uint256 activeCount = 0;
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            
            if (isMember || hasBalance || hasLoans) {
                activeCount++;
            }
        }

        activePoolIds = new uint256[](activeCount);
        uint256 index = 0;

        // Populate active pool IDs
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            
            if (isMember || hasBalance || hasLoans) {
                activePoolIds[index] = pid;
                index++;
            }
        }
    }

    /// @notice Get direct agreement summary for a Position NFT
    /// @param tokenId The token ID
    /// @return directSummary The direct agreement summary
    function getPositionDirectSummary(uint256 tokenId) 
        external 
        view 
        returns (DirectAgreementSummary memory directSummary) 
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibAppStorage.AppStorage storage store = s();
        uint256 totalLocked = 0;
        uint256 totalLent = 0;
        uint256 totalBorrowed = 0;
        for (uint256 pid = 1; pid <= store.poolCount; pid++) {
            Types.PoolData storage pool = store.pools[pid];
            if (!pool.initialized) continue;
            LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
            totalLocked += enc.directLocked;
            totalLent += enc.directLent + enc.directOfferEscrow;
            totalBorrowed += ds.directBorrowedPrincipal[positionKey][pid];
        }

        (,, uint256 activeAgreements) = LibPositionList.meta(ds.borrowerAgreements, positionKey);
        directSummary = DirectAgreementSummary({
            totalLocked: totalLocked,
            totalLent: totalLent,
            totalBorrowed: totalBorrowed,
            activeAgreementCount: activeAgreements
        });
    }

    function _getPositionDirectAgreementIds(uint256 tokenId)
        internal
        view
        returns (uint256[] memory agreementIds)
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (uint256[] memory borrowerAgreements,) = LibDirectStorage.borrowerAgreementsPage(ds, positionKey, 0, 0);
        (uint256[] memory lenderAgreements,) = LibDirectStorage.lenderAgreementsPage(ds, positionKey, 0, 0);

        agreementIds = new uint256[](borrowerAgreements.length + lenderAgreements.length);
        uint256 count = 0;

        for (uint256 i = 0; i < borrowerAgreements.length; i++) {
            agreementIds[count++] = borrowerAgreements[i];
        }

        for (uint256 i = 0; i < lenderAgreements.length; i++) {
            uint256 agreementId = lenderAgreements[i];
            bool exists = false;
            for (uint256 j = 0; j < count; j++) {
                if (agreementIds[j] == agreementId) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                agreementIds[count++] = agreementId;
            }
        }

        assembly {
            mstore(agreementIds, count)
        }
    }

    /// @notice Get direct agreement IDs for a Position NFT (borrower + lender, de-duplicated)
    function getPositionDirectAgreementIds(uint256 tokenId)
        external
        view
        returns (uint256[] memory agreementIds)
    {
        return _getPositionDirectAgreementIds(tokenId);
    }

    /// @notice Get direct agreements tied to a Position NFT with role metadata.
    function getPositionDirectAgreements(uint256 tokenId)
        external
        view
        returns (PositionDirectAgreement[] memory agreements)
    {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256[] memory ids = _getPositionDirectAgreementIds(tokenId);
        agreements = new PositionDirectAgreement[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 agreementId = ids[i];
            DirectTypes.DirectAgreement memory agreement = ds.agreements[agreementId];
            bool isBorrower = agreement.borrowerPositionId == tokenId;
            bool isLender = agreement.lenderPositionId == tokenId;
            agreements[i] = PositionDirectAgreement({
                agreement: agreement,
                isBorrower: isBorrower,
                isLender: isLender
            });
        }
    }

    /// @notice Summarize direct commitments per asset for a Position NFT.
    function getPositionDirectSummaryByAsset(uint256 tokenId)
        external
        view
        returns (DirectAssetSummary[] memory summaries)
    {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256[] memory ids = _getPositionDirectAgreementIds(tokenId);
        DirectAssetSummary[] memory temp = new DirectAssetSummary[](ids.length * 2);
        uint256 count = 0;

        for (uint256 i = 0; i < ids.length; i++) {
            DirectTypes.DirectAgreement memory agreement = ds.agreements[ids[i]];
            if (agreement.status != DirectTypes.DirectStatus.Active) {
                continue;
            }

            bool isBorrower = agreement.borrowerPositionId == tokenId;
            bool isLender = agreement.lenderPositionId == tokenId;

            if (isBorrower) {
                count = _addAssetSummary(
                    temp,
                    count,
                    agreement.borrowAsset,
                    0,
                    0,
                    agreement.principal
                );
                count = _addAssetSummary(
                    temp,
                    count,
                    agreement.collateralAsset,
                    0,
                    agreement.collateralLockAmount,
                    0
                );
            }

            if (isLender) {
                count = _addAssetSummary(
                    temp,
                    count,
                    agreement.borrowAsset,
                    agreement.principal,
                    0,
                    0
                );
            }
        }

        summaries = new DirectAssetSummary[](count);
        for (uint256 i = 0; i < count; i++) {
            summaries[i] = temp[i];
        }
    }

    /// @notice Get pool-only position data across all relevant pools (excludes direct debt).
    function getPositionPoolStates(uint256 tokenId)
        external
        view
        returns (PoolPositionData[] memory pools)
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        LibAppStorage.AppStorage storage store = s();
        uint256 poolCount = store.poolCount;

        uint256 relevantCount = 0;
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            if (isMember || hasBalance || hasLoans) {
                relevantCount++;
            }
        }

        pools = new PoolPositionData[](relevantCount);
        uint256 index = 0;
        for (uint256 pid = 1; pid <= poolCount; pid++) {
            Types.PoolData storage p = store.pools[pid];
            if (!p.initialized) continue;
            bool isMember = LibPoolMembership.isMember(positionKey, pid);
            bool hasBalance = p.userPrincipal[positionKey] > 0;
            bool hasLoans = _hasActiveLoans(p, positionKey);
            if (isMember || hasBalance || hasLoans) {
                pools[index] = PoolPositionData({
                    poolId: pid,
                    underlying: p.underlying,
                    principal: p.userPrincipal[positionKey],
                    yield: LibFeeIndex.pendingYield(pid, positionKey),
                    hasActiveLoan: hasLoans,
                    totalDebt: _calculatePoolDebt(p, positionKey),
                    isMember: isMember
                });
                index++;
            }
        }
    }

    /// @notice Get pool-only position data for a specific pool (excludes direct debt).
    function getPositionPoolDataPoolOnly(uint256 tokenId, uint256 pid)
        external
        view
        returns (PoolPositionData memory poolData)
    {
        bytes32 positionKey = _getPositionKey(tokenId);
        Types.PoolData storage p = _pool(pid);

        bool isMember = LibPoolMembership.isMember(positionKey, pid);
        bool hasActiveLoans = _hasActiveLoans(p, positionKey);

        poolData = PoolPositionData({
            poolId: pid,
            underlying: p.underlying,
            principal: p.userPrincipal[positionKey],
            yield: LibFeeIndex.pendingYield(pid, positionKey),
            hasActiveLoan: hasActiveLoans,
            totalDebt: _calculatePoolDebt(p, positionKey),
            isMember: isMember
        });
    }

    /// @notice Get position token IDs and position keys for an owner.
    function getUserPositions(address owner)
        external
        view
        returns (PositionOwnerSummary[] memory positions)
    {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        if (address(nft) == address(0)) {
            return new PositionOwnerSummary[](0);
        }
        uint256 balance = nft.balanceOf(owner);
        positions = new PositionOwnerSummary[](balance);
        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = nft.tokenOfOwnerByIndex(owner, i);
            positions[i] = PositionOwnerSummary({
                tokenId: tokenId,
                positionKey: _getPositionKey(tokenId)
            });
        }
    }

    function _addAssetSummary(
        DirectAssetSummary[] memory summaries,
        uint256 count,
        address asset,
        uint256 lent,
        uint256 locked,
        uint256 borrowed
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < count; i++) {
            if (summaries[i].asset == asset) {
                summaries[i].lent += lent;
                summaries[i].locked += locked;
                summaries[i].borrowed += borrowed;
                return count;
            }
        }
        summaries[count] = DirectAssetSummary({
            asset: asset,
            lent: lent,
            locked: locked,
            borrowed: borrowed
        });
        return count + 1;
    }

    /// @notice Get function selectors for this facet
    /// @return selectorsArr Array of function selectors
    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](14);
        selectorsArr[0] = MultiPoolPositionViewFacet.getMultiPoolPositionState.selector;
        selectorsArr[1] = MultiPoolPositionViewFacet.getPositionPoolMemberships.selector;
        selectorsArr[2] = MultiPoolPositionViewFacet.getPositionPoolData.selector;
        selectorsArr[3] = MultiPoolPositionViewFacet.isPositionMemberOfPool.selector;
        selectorsArr[4] = MultiPoolPositionViewFacet.getPositionAggregatedSummary.selector;
        selectorsArr[5] = MultiPoolPositionViewFacet.getPositionActivePools.selector;
        selectorsArr[6] = MultiPoolPositionViewFacet.getPositionDirectSummary.selector;
        selectorsArr[7] = MultiPoolPositionViewFacet.getPositionDirectAgreementIds.selector;
        selectorsArr[8] = MultiPoolPositionViewFacet.getPositionDirectAgreements.selector;
        selectorsArr[9] = MultiPoolPositionViewFacet.getPositionDirectSummaryByAsset.selector;
        selectorsArr[10] = MultiPoolPositionViewFacet.getPositionPoolStates.selector;
        selectorsArr[11] = MultiPoolPositionViewFacet.getPositionPoolDataPoolOnly.selector;
        selectorsArr[12] = MultiPoolPositionViewFacet.getUserPositions.selector;
        selectorsArr[13] = MultiPoolPositionViewFacet.selectors.selector;
    }
}
