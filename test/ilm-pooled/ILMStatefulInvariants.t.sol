// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ILMTestBase, IILMTestHarness, MockIlmOracleAdapterIntegration} from "./ILMTestBase.sol";
import {IILMPooledFacet} from "../../src/ilm-pooled/interfaces/IILMPooledFacet.sol";
import {IILMPooledLiquidationFacet} from "../../src/ilm-pooled/interfaces/IILMPooledLiquidationFacet.sol";
import {IILMPooledViewFacet} from "../../src/ilm-pooled/interfaces/IILMPooledViewFacet.sol";
import {LibIlmIndexing} from "../../src/ilm-pooled/libraries/LibIlmIndexing.sol";
import {IlmTypes} from "../../src/ilm-pooled/libraries/IlmTypes.sol";

contract ILMPooledStatefulHandler is Test {
    IILMPooledFacet internal pooled;
    IILMPooledLiquidationFacet internal pooledLiquidation;
    IILMPooledViewFacet internal pooledView;
    IILMTestHarness internal harness;
    MockIlmOracleAdapterIntegration internal oracle;

    uint256 internal loanPoolId;
    uint256 internal collateralPoolId;
    uint256 internal moduleId;
    uint256[] internal marketIds;
    uint256[] internal positionIds;
    bytes32[] internal positionKeys;
    address[] internal actors;

    uint256 internal expectedLoanAciTotal;
    uint256 internal expectedCollateralAciTotal;
    bool internal aciIncreaseGateViolation;
    bool internal aciDecreaseAlwaysOnViolation;
    bool internal badDebtIsolationViolation;

    constructor(
        IILMPooledFacet pooled_,
        IILMPooledLiquidationFacet pooledLiquidation_,
        IILMPooledViewFacet pooledView_,
        IILMTestHarness harness_,
        MockIlmOracleAdapterIntegration oracle_,
        uint256 loanPoolId_,
        uint256 collateralPoolId_,
        uint256 moduleId_,
        uint256[] memory marketIds_,
        uint256[] memory positionIds_,
        bytes32[] memory positionKeys_,
        address[] memory actors_
    ) {
        pooled = pooled_;
        pooledLiquidation = pooledLiquidation_;
        pooledView = pooledView_;
        harness = harness_;
        oracle = oracle_;
        loanPoolId = loanPoolId_;
        collateralPoolId = collateralPoolId_;
        moduleId = moduleId_;
        for (uint256 i; i < marketIds_.length; i++) {
            marketIds.push(marketIds_[i]);
        }
        for (uint256 i; i < positionIds_.length; i++) {
            positionIds.push(positionIds_[i]);
            positionKeys.push(positionKeys_[i]);
        }
        for (uint256 i; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }
        expectedLoanAciTotal = harness.getPoolActiveCreditPrincipalTotal(loanPoolId);
        expectedCollateralAciTotal = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
    }

    function actSupply(uint256 amountSeed, uint256 actorSeed, uint256 positionSeed, uint256 marketSeed) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 positionId = _positionId(positionSeed);
        bytes32 positionKey = _positionKey(positionSeed);
        uint256 amount = bound(amountSeed, 1, 250_000);
        bool gatePaused = harness.getModuleAciPausedRaw();

        uint256 encBefore = harness.getEncumberedForModule(positionKey, loanPoolId, moduleId);
        uint256 totalBefore = harness.getPoolActiveCreditPrincipalTotal(loanPoolId);
        uint256 userBefore = harness.getPoolUserActiveCreditEncumbrancePrincipal(loanPoolId, positionKey);

        vm.startPrank(_actor(actorSeed));
        try pooled.pooledSupply(positionId, marketId, amount) {
            uint256 encAfter = harness.getEncumberedForModule(positionKey, loanPoolId, moduleId);
            uint256 totalAfter = harness.getPoolActiveCreditPrincipalTotal(loanPoolId);
            uint256 userAfter = harness.getPoolUserActiveCreditEncumbrancePrincipal(loanPoolId, positionKey);
            uint256 delta = encAfter > encBefore ? encAfter - encBefore : 0;
            _checkIncreaseGate(loanPoolId, gatePaused, delta, totalBefore, totalAfter, userBefore, userAfter);
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actWithdraw(uint256 amountSeed, uint256 actorSeed, uint256 positionSeed, uint256 marketSeed) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 positionId = _positionId(positionSeed);
        bytes32 positionKey = _positionKey(positionSeed);
        uint256 amount = bound(amountSeed, 1, 250_000);

        uint256 encBefore = harness.getEncumberedForModule(positionKey, loanPoolId, moduleId);
        uint256 totalBefore = harness.getPoolActiveCreditPrincipalTotal(loanPoolId);
        uint256 userBefore = harness.getPoolUserActiveCreditEncumbrancePrincipal(loanPoolId, positionKey);

        vm.startPrank(_actor(actorSeed));
        try pooled.pooledWithdraw(positionId, marketId, amount) returns (uint256) {
            uint256 encAfter = harness.getEncumberedForModule(positionKey, loanPoolId, moduleId);
            uint256 totalAfter = harness.getPoolActiveCreditPrincipalTotal(loanPoolId);
            uint256 userAfter = harness.getPoolUserActiveCreditEncumbrancePrincipal(loanPoolId, positionKey);
            uint256 delta = encBefore > encAfter ? encBefore - encAfter : 0;
            _checkDecreaseAlwaysOn(loanPoolId, delta, totalBefore, totalAfter, userBefore, userAfter);
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actAddCollateral(uint256 amountSeed, uint256 actorSeed, uint256 positionSeed, uint256 marketSeed) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 positionId = _positionId(positionSeed);
        bytes32 positionKey = _positionKey(positionSeed);
        uint256 amount = bound(amountSeed, 1, 250_000);
        bool gatePaused = harness.getModuleAciPausedRaw();

        uint256 encBefore = harness.getEncumberedForModule(positionKey, collateralPoolId, moduleId);
        uint256 totalBefore = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
        uint256 userBefore = harness.getPoolUserActiveCreditEncumbrancePrincipal(collateralPoolId, positionKey);

        vm.startPrank(_actor(actorSeed));
        try pooled.pooledAddCollateral(positionId, marketId, amount) {
            uint256 encAfter = harness.getEncumberedForModule(positionKey, collateralPoolId, moduleId);
            uint256 totalAfter = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
            uint256 userAfter = harness.getPoolUserActiveCreditEncumbrancePrincipal(collateralPoolId, positionKey);
            uint256 delta = encAfter > encBefore ? encAfter - encBefore : 0;
            _checkIncreaseGate(collateralPoolId, gatePaused, delta, totalBefore, totalAfter, userBefore, userAfter);
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actRemoveCollateral(
        uint256 amountSeed,
        uint256 actorSeed,
        uint256 positionSeed,
        uint256 marketSeed
    ) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 positionId = _positionId(positionSeed);
        bytes32 positionKey = _positionKey(positionSeed);
        uint256 amount = bound(amountSeed, 1, 250_000);

        uint256 encBefore = harness.getEncumberedForModule(positionKey, collateralPoolId, moduleId);
        uint256 totalBefore = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
        uint256 userBefore = harness.getPoolUserActiveCreditEncumbrancePrincipal(collateralPoolId, positionKey);

        vm.startPrank(_actor(actorSeed));
        try pooled.pooledRemoveCollateral(positionId, marketId, amount) {
            uint256 encAfter = harness.getEncumberedForModule(positionKey, collateralPoolId, moduleId);
            uint256 totalAfter = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
            uint256 userAfter = harness.getPoolUserActiveCreditEncumbrancePrincipal(collateralPoolId, positionKey);
            uint256 delta = encBefore > encAfter ? encBefore - encAfter : 0;
            _checkDecreaseAlwaysOn(collateralPoolId, delta, totalBefore, totalAfter, userBefore, userAfter);
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actBorrow(uint256 amountSeed, uint256 actorSeed, uint256 positionSeed, uint256 marketSeed) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 positionId = _positionId(positionSeed);
        uint256 amount = bound(amountSeed, 1, 200_000);

        vm.startPrank(_actor(actorSeed));
        try pooled.pooledBorrow(positionId, marketId, amount) {
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actRepay(uint256 amountSeed, uint256 actorSeed, uint256 positionSeed, uint256 marketSeed) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 positionId = _positionId(positionSeed);
        uint256 amount = bound(amountSeed, 1, 200_000);

        vm.startPrank(_actor(actorSeed));
        try pooled.pooledRepay(positionId, marketId, amount) returns (uint256) {
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actLiquidate(
        uint256 debtSeed,
        uint256 actorSeed,
        uint256 borrowerSeed,
        uint256 liquidatorSeed,
        uint256 marketSeed
    ) external {
        uint256 marketId = _marketId(marketSeed);
        bytes32 otherHash = _otherMarketHash(marketId);
        uint256 borrowerPositionId = _positionId(borrowerSeed);
        bytes32 borrowerKey = _positionKey(borrowerSeed);
        uint256 liquidatorPositionId = _positionId(liquidatorSeed);
        uint256 debtToCover = bound(debtSeed, 1, 200_000);

        uint256 encBefore = harness.getEncumberedForModule(borrowerKey, collateralPoolId, moduleId);
        uint256 totalBefore = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
        uint256 userBefore = harness.getPoolUserActiveCreditEncumbrancePrincipal(collateralPoolId, borrowerKey);

        vm.startPrank(_actor(actorSeed));
        try pooledLiquidation.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, marketId, debtToCover) returns (
            uint256,
            uint256
        ) {
            uint256 encAfter = harness.getEncumberedForModule(borrowerKey, collateralPoolId, moduleId);
            uint256 totalAfter = harness.getPoolActiveCreditPrincipalTotal(collateralPoolId);
            uint256 userAfter = harness.getPoolUserActiveCreditEncumbrancePrincipal(collateralPoolId, borrowerKey);
            uint256 delta = encBefore > encAfter ? encBefore - encAfter : 0;
            _checkDecreaseAlwaysOn(collateralPoolId, delta, totalBefore, totalAfter, userBefore, userAfter);
            _checkOtherMarketUnchanged(marketId, otherHash);
        } catch {}
        vm.stopPrank();
    }

    function actSetOraclePrice(uint256 priceSeed) external {
        uint256 priceRay = bound(priceSeed, 5e26, 2e27);
        oracle.setPriceRay(priceRay);
    }

    function actWarp(uint256 deltaSeed) external {
        uint256 dt = bound(deltaSeed, 1 minutes, 6 hours);
        vm.warp(block.timestamp + dt);
    }

    function actToggleModuleAciPaused(uint256 pausedSeed) external {
        harness.setModuleAciPausedRaw(pausedSeed % 2 == 1);
    }

    function getExpectedLoanAciTotal() external view returns (uint256) {
        return expectedLoanAciTotal;
    }

    function getExpectedCollateralAciTotal() external view returns (uint256) {
        return expectedCollateralAciTotal;
    }

    function getAciIncreaseGateViolation() external view returns (bool) {
        return aciIncreaseGateViolation;
    }

    function getAciDecreaseAlwaysOnViolation() external view returns (bool) {
        return aciDecreaseAlwaysOnViolation;
    }

    function getBadDebtIsolationViolation() external view returns (bool) {
        return badDebtIsolationViolation;
    }

    function _checkIncreaseGate(
        uint256 poolId,
        bool gatePaused,
        uint256 delta,
        uint256 totalBefore,
        uint256 totalAfter,
        uint256 userBefore,
        uint256 userAfter
    ) internal {
        if (delta == 0) {
            if (totalAfter != totalBefore || userAfter != userBefore) {
                aciIncreaseGateViolation = true;
            }
            return;
        }

        if (gatePaused) {
            if (totalAfter != totalBefore || userAfter != userBefore) {
                aciIncreaseGateViolation = true;
            }
        } else {
            if (totalAfter != totalBefore + delta || userAfter != userBefore + delta) {
                aciIncreaseGateViolation = true;
            }
            if (poolId == loanPoolId) {
                expectedLoanAciTotal += delta;
            } else {
                expectedCollateralAciTotal += delta;
            }
        }
    }

    function _checkDecreaseAlwaysOn(
        uint256 poolId,
        uint256 delta,
        uint256 totalBefore,
        uint256 totalAfter,
        uint256 userBefore,
        uint256 userAfter
    ) internal {
        if (delta == 0) {
            if (totalAfter != totalBefore || userAfter != userBefore) {
                aciDecreaseAlwaysOnViolation = true;
            }
            return;
        }

        uint256 expectedDecrease = delta < userBefore ? delta : userBefore;
        if (totalAfter + expectedDecrease != totalBefore) {
            aciDecreaseAlwaysOnViolation = true;
        }
        if (userAfter + expectedDecrease != userBefore) {
            aciDecreaseAlwaysOnViolation = true;
        }

        if (poolId == loanPoolId) {
            if (expectedLoanAciTotal >= expectedDecrease) {
                expectedLoanAciTotal -= expectedDecrease;
            } else {
                expectedLoanAciTotal = 0;
            }
        } else {
            if (expectedCollateralAciTotal >= expectedDecrease) {
                expectedCollateralAciTotal -= expectedDecrease;
            } else {
                expectedCollateralAciTotal = 0;
            }
        }
    }

    function _otherMarketHash(uint256 actedMarketId) internal view returns (bytes32) {
        for (uint256 i; i < marketIds.length; i++) {
            if (marketIds[i] == actedMarketId) {
                continue;
            }
            return _marketHash(marketIds[i]);
        }
        return bytes32(0);
    }

    function _checkOtherMarketUnchanged(uint256 actedMarketId, bytes32 hashBefore) internal {
        for (uint256 i; i < marketIds.length; i++) {
            if (marketIds[i] == actedMarketId) {
                continue;
            }
            if (_marketHash(marketIds[i]) != hashBefore) {
                badDebtIsolationViolation = true;
            }
            return;
        }
    }

    function _marketHash(uint256 marketId) internal view returns (bytes32) {
        IlmTypes.IlmMarket memory market = pooledView.getPooledMarket(marketId);
        return keccak256(abi.encode(market));
    }

    function _marketId(uint256 seed) internal view returns (uint256) {
        return marketIds[seed % marketIds.length];
    }

    function _positionId(uint256 seed) internal view returns (uint256) {
        return positionIds[seed % positionIds.length];
    }

    function _positionKey(uint256 seed) internal view returns (bytes32) {
        return positionKeys[seed % positionKeys.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

contract ILMStatefulInvariantsTest is StdInvariant, ILMTestBase {
    uint256 internal constant SOLVENCY_DUST_TOLERANCE = 1_000_000;
    uint256 internal constant INITIAL_PRINCIPAL_PER_POSITION = 5_000_000;
    uint256 internal constant TRACKED_BALANCE_SEED = 1_000_000_000_000;

    ILMPooledStatefulHandler internal handler;

    uint256 internal marketA;
    uint256 internal marketB;
    uint256[] internal positionIds;
    bytes32[] internal positionKeys;
    address[] internal actors;

    function setUp() public {
        setUpBase();

        marketA = createDefaultMarket(500, 100);
        marketB = createDefaultMarket(600, 200);

        pooledAdmin.setPooledRateStrategy(marketA, 1_000, 8_000, 1_000_000_000, 2_000_000_000, 3_000_000_000);
        pooledAdmin.setPooledRateStrategy(marketB, 1_200, 8_500, 1_000_000_000, 2_000_000_000, 4_000_000_000);

        _seedPositionsAndPools();
        _seedInitialMarketState();

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = marketA;
        marketIds[1] = marketB;

        handler = new ILMPooledStatefulHandler(
            pooled,
            pooledLiquidation,
            pooledView,
            harness,
            oracle,
            LOAN_POOL_ID,
            COLLATERAL_POOL_ID,
            moduleId,
            marketIds,
            positionIds,
            positionKeys,
            actors
        );

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ILMPooledStatefulHandler.actSupply.selector;
        selectors[1] = ILMPooledStatefulHandler.actWithdraw.selector;
        selectors[2] = ILMPooledStatefulHandler.actAddCollateral.selector;
        selectors[3] = ILMPooledStatefulHandler.actRemoveCollateral.selector;
        selectors[4] = ILMPooledStatefulHandler.actBorrow.selector;
        selectors[5] = ILMPooledStatefulHandler.actRepay.selector;
        selectors[6] = ILMPooledStatefulHandler.actLiquidate.selector;
        selectors[7] = ILMPooledStatefulHandler.actSetOraclePrice.selector;
        selectors[8] = ILMPooledStatefulHandler.actWarp.selector;
        selectors[9] = ILMPooledStatefulHandler.actToggleModuleAciPaused.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Property 28: Non-Negative Available Principal Invariant
    function invariant_property28_nonNegativeAvailablePrincipal() public {
        for (uint256 i; i < positionKeys.length; i++) {
            _assertPoolPrincipalBound(LOAN_POOL_ID, positionKeys[i]);
            _assertPoolPrincipalBound(COLLATERAL_POOL_ID, positionKeys[i]);
        }
    }

    /// @dev Property 29: Scaled Totals Aggregate Consistency
    function invariant_property29_scaledTotalsAggregateConsistency() public {
        _assertScaledTotalsConsistency(marketA);
        _assertScaledTotalsConsistency(marketB);
    }

    /// @dev Property 30: Solvency Accounting Equation
    function invariant_property30_solvencyAccountingEquation() public {
        _assertSolvencyEquation(marketA);
        _assertSolvencyEquation(marketB);
    }

    /// @dev Property 31: Bad Debt Market Isolation
    function invariant_property31_badDebtMarketIsolation() public {
        assertFalse(handler.getBadDebtIsolationViolation());
    }

    /// @dev Property 33: Active Credit Increase Gate (stateful checks)
    function invariant_property33_activeCreditIncreaseGate() public {
        assertFalse(handler.getAciIncreaseGateViolation());
        assertEq(
            harness.getPoolActiveCreditPrincipalTotal(LOAN_POOL_ID),
            handler.getExpectedLoanAciTotal()
        );
        assertEq(
            harness.getPoolActiveCreditPrincipalTotal(COLLATERAL_POOL_ID),
            handler.getExpectedCollateralAciTotal()
        );
    }

    /// @dev Property 34: Active Credit Decrease Always On
    function invariant_property34_activeCreditDecreaseAlwaysOn() public {
        assertFalse(handler.getAciDecreaseAlwaysOnViolation());
    }

    /// @dev Requirement 15.7: Deferred protocol claim bounded by current borrow assets.
    function invariant_marketProtocolFeeAssetsBoundedByBorrowAssets() public {
        _assertProtocolFeeBound(marketA);
        _assertProtocolFeeBound(marketB);
    }

    function _seedPositionsAndPools() internal {
        (uint256 aliceId, bytes32 aliceKey) = mintPosition(ALICE, LOAN_POOL_ID);
        (uint256 bobId, bytes32 bobKey) = mintPosition(BOB, LOAN_POOL_ID);
        (uint256 carolId, bytes32 carolKey) = mintPosition(CAROL, LOAN_POOL_ID);

        positionIds.push(aliceId);
        positionIds.push(bobId);
        positionIds.push(carolId);

        positionKeys.push(aliceKey);
        positionKeys.push(bobKey);
        positionKeys.push(carolKey);

        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);

        uint256 totalPrincipal = INITIAL_PRINCIPAL_PER_POSITION * positionKeys.length;
        for (uint256 i; i < positionKeys.length; i++) {
            harness.setPoolPrincipal(LOAN_POOL_ID, positionKeys[i], INITIAL_PRINCIPAL_PER_POSITION);
            harness.setPoolPrincipal(COLLATERAL_POOL_ID, positionKeys[i], INITIAL_PRINCIPAL_PER_POSITION);
        }

        harness.setPoolTotalsAndTracked(LOAN_POOL_ID, totalPrincipal, TRACKED_BALANCE_SEED);
        harness.setPoolTotalsAndTracked(COLLATERAL_POOL_ID, totalPrincipal, TRACKED_BALANCE_SEED);
    }

    function _seedInitialMarketState() internal {
        vm.startPrank(ALICE);
        pooled.pooledSupply(positionIds[0], marketA, 1_200_000);
        vm.stopPrank();

        vm.startPrank(BOB);
        pooled.pooledAddCollateral(positionIds[1], marketA, 1_200_000);
        pooled.pooledBorrow(positionIds[1], marketA, 500_000);
        vm.stopPrank();

        vm.startPrank(CAROL);
        pooled.pooledSupply(positionIds[2], marketB, 900_000);
        pooled.pooledAddCollateral(positionIds[2], marketB, 700_000);
        pooled.pooledBorrow(positionIds[2], marketB, 300_000);
        vm.stopPrank();
    }

    function _assertPoolPrincipalBound(uint256 poolId, bytes32 positionKey) internal {
        uint256 principal = harness.getPoolPrincipal(poolId, positionKey);
        uint256 encumbered = harness.getEncumberedForModule(positionKey, poolId, moduleId);
        uint256 available = harness.getAvailablePrincipal(poolId, positionKey);
        assertLe(encumbered, principal);
        assertLe(available + encumbered, principal);
    }

    function _assertScaledTotalsConsistency(uint256 marketId) internal {
        IlmTypes.IlmMarket memory market = pooledView.getPooledMarket(marketId);
        uint256 scaledSupplySum;
        uint256 scaledDebtSum;
        for (uint256 i; i < positionIds.length; i++) {
            IlmTypes.IlmPosition memory position = pooledView.getPooledPosition(marketId, positionIds[i]);
            scaledSupplySum += position.scaledSupply;
            scaledDebtSum += position.scaledDebt;
        }
        assertEq(market.scaledSupplyTotal, scaledSupplySum);
        assertEq(market.scaledVariableDebtTotal, scaledDebtSum);
    }

    function _assertSolvencyEquation(uint256 marketId) internal {
        IlmTypes.IlmMarket memory market = pooledView.getPooledMarket(marketId);
        uint256 outstandingBorrow =
            LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, market.variableBorrowIndexRay);
        uint256 encumberedLenderCapital =
            LibIlmIndexing.fromScaledSupply(market.scaledSupplyTotal, market.liquidityIndexRay);
        uint256 rhs = encumberedLenderCapital > market.badDebt ? encumberedLenderCapital - market.badDebt : 0;
        assertApproxEqAbs(market.availableLiquidity + outstandingBorrow, rhs, SOLVENCY_DUST_TOLERANCE);
    }

    function _assertProtocolFeeBound(uint256 marketId) internal {
        IlmTypes.IlmMarket memory market = pooledView.getPooledMarket(marketId);
        uint256 borrowAssets = LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, market.variableBorrowIndexRay);
        uint256 claim = pooledView.getPooledMarketProtocolFeeAssets(marketId);
        assertLe(claim, borrowAssets);
    }
}
