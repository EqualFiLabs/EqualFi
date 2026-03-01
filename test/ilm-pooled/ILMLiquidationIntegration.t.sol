// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILMTestBase} from "./ILMTestBase.sol";
import {IILMEvents} from "../../src/interfaces/IILMEvents.sol";
import {IlmTypes} from "../../src/libraries/IlmTypes.sol";
import {Vm} from "forge-std/Vm.sol";

contract ILMLiquidationIntegrationTest is ILMTestBase, IILMEvents {
    function setUp() public {
        setUpBase();
    }

    function testIntegration_liquidationLifecycle() public {
        uint256 marketId = createDefaultMarket(500, 0);

        (uint256 lenderPositionId, bytes32 lenderKey) = mintPosition(ALICE, LOAN_POOL_ID);
        (uint256 borrowerPositionId, bytes32 borrowerKey) = mintPosition(BOB, LOAN_POOL_ID);
        (uint256 liquidatorPositionId, bytes32 liquidatorKey) = mintPosition(CAROL, LOAN_POOL_ID);

        harness.setPoolPrincipal(LOAN_POOL_ID, lenderKey, 1_000);
        harness.setPoolPrincipal(LOAN_POOL_ID, liquidatorKey, 1_000);
        harness.setPoolPrincipal(COLLATERAL_POOL_ID, borrowerKey, 1_000);
        harness.setPoolTotalsAndTracked(LOAN_POOL_ID, 2_000, 2_000);
        harness.setPoolTotalsAndTracked(COLLATERAL_POOL_ID, 1_000, 1_000);

        vm.prank(ALICE);
        pooled.pooledSupply(lenderPositionId, marketId, 500);

        vm.prank(BOB);
        pooled.pooledAddCollateral(borrowerPositionId, marketId, 300);

        vm.prank(BOB);
        pooled.pooledBorrow(borrowerPositionId, marketId, 200);

        vm.warp(block.timestamp + 1 days);
        oracle.setPriceRay(5e26);

        vm.recordLogs();
        vm.prank(CAROL);
        (uint256 debtLiquidated, uint256 seizedNet) =
            pooledLiquidation.pooledLiquidationCall(liquidatorPositionId, borrowerPositionId, marketId, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertLiquidationEvent(logs, marketId, borrowerKey, liquidatorKey, 100, 100, 210, 0);
        _assertLiquidationRevenueEvent(logs, marketId, borrowerKey, liquidatorKey, 210, 0, 210);

        assertEq(debtLiquidated, 100);
        assertEq(seizedNet, 210);

        IlmTypes.IlmMarket memory market = pooledView.getPooledMarket(marketId);
        IlmTypes.IlmPosition memory borrower = pooledView.getPooledPosition(marketId, borrowerPositionId);

        assertEq(market.availableLiquidity, 400);
        assertEq(market.scaledVariableDebtTotal, 100);
        assertEq(borrower.scaledDebt, 100);

        assertEq(harness.getPoolPrincipal(LOAN_POOL_ID, liquidatorKey), 900);
        assertEq(harness.getPoolPrincipal(COLLATERAL_POOL_ID, liquidatorKey), 210);
        assertEq(harness.getEncumberedForModule(borrowerKey, COLLATERAL_POOL_ID, moduleId), 90);
    }

    function _assertLiquidationEvent(
        Vm.Log[] memory logs,
        uint256 marketId,
        bytes32 borrowerKey,
        bytes32 liquidatorKey,
        uint256 debtLiquidated,
        uint256 scaledDebtBurned,
        uint256 collateralSeized,
        uint256 badDebtAdded
    ) internal pure {
        bytes32 sig = keccak256("IlmLiquidation(uint256,bytes32,bytes32,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) != marketId) continue;
            if (logs[i].topics[2] != borrowerKey) continue;
            if (logs[i].topics[3] != liquidatorKey) continue;
            (uint256 a, uint256 b, uint256 c, uint256 d) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            if (a == debtLiquidated && b == scaledDebtBurned && c == collateralSeized && d == badDebtAdded) return;
        }
        revert("IlmLiquidation not found");
    }

    function _assertLiquidationRevenueEvent(
        Vm.Log[] memory logs,
        uint256 marketId,
        bytes32 borrowerKey,
        bytes32 liquidatorKey,
        uint256 grossSeized,
        uint256 protocolFeeCollateral,
        uint256 netSeized
    ) internal pure {
        bytes32 sig = keccak256("IlmLiquidationRevenue(uint256,bytes32,bytes32,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) != marketId) continue;
            if (logs[i].topics[2] != borrowerKey) continue;
            if (logs[i].topics[3] != liquidatorKey) continue;
            (uint256 a, uint256 b, uint256 c) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            if (a == grossSeized && b == protocolFeeCollateral && c == netSeized) return;
        }
        revert("IlmLiquidationRevenue not found");
    }
}
