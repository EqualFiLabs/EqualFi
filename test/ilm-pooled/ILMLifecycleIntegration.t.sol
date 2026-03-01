// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILMTestBase} from "./ILMTestBase.sol";
import {IILMEvents} from "../../src/interfaces/IILMEvents.sol";
import {IlmTypes} from "../../src/libraries/IlmTypes.sol";
import {Vm} from "forge-std/Vm.sol";

contract ILMLifecycleIntegrationTest is ILMTestBase, IILMEvents {
    function setUp() public {
        setUpBase();
    }

    function testIntegration_fullLendingLifecycle() public {
        uint256 expectedMarketId = 1;

        vm.recordLogs();
        uint256 marketId = createDefaultMarket(500, 0);
        assertEq(marketId, expectedMarketId);
        _assertMarketCreated(vm.getRecordedLogs(), expectedMarketId, LOAN_POOL_ID, COLLATERAL_POOL_ID);

        (uint256 positionId, bytes32 positionKey) = mintPosition(ALICE, LOAN_POOL_ID);
        harness.setPoolPrincipal(LOAN_POOL_ID, positionKey, 1_000);
        harness.setPoolPrincipal(COLLATERAL_POOL_ID, positionKey, 1_000);
        harness.setPoolTotalsAndTracked(LOAN_POOL_ID, 1_000, 1_000);
        harness.setPoolTotalsAndTracked(COLLATERAL_POOL_ID, 1_000, 1_000);

        vm.recordLogs();
        vm.prank(ALICE);
        pooled.pooledSupply(positionId, marketId, 400);
        _assertSupplyEvent(vm.getRecordedLogs(), marketId, positionKey, 400, 400);

        vm.prank(ALICE);
        pooled.pooledAddCollateral(positionId, marketId, 300);

        vm.recordLogs();
        vm.prank(ALICE);
        pooled.pooledBorrow(positionId, marketId, 200);
        _assertBorrowEvent(vm.getRecordedLogs(), marketId, positionKey, 200, 200);

        vm.recordLogs();
        vm.prank(ALICE);
        uint256 repaid = pooled.pooledRepay(positionId, marketId, 200);
        assertEq(repaid, 200);
        _assertRepayEvent(vm.getRecordedLogs(), marketId, positionKey, 200, 200);

        vm.prank(ALICE);
        pooled.pooledRemoveCollateral(positionId, marketId, 300);

        vm.recordLogs();
        vm.prank(ALICE);
        uint256 withdrawn = pooled.pooledWithdraw(positionId, marketId, 400);
        assertEq(withdrawn, 400);
        _assertWithdrawEvent(vm.getRecordedLogs(), marketId, positionKey, 400, 400);

        IlmTypes.IlmMarket memory market = pooledView.getPooledMarket(marketId);
        IlmTypes.IlmPosition memory position = pooledView.getPooledPosition(marketId, positionId);

        assertEq(market.scaledSupplyTotal, 0);
        assertEq(market.scaledVariableDebtTotal, 0);
        assertEq(market.availableLiquidity, 0);

        assertEq(position.scaledSupply, 0);
        assertEq(position.scaledDebt, 0);
        assertFalse(position.useAsCollateral);

        assertEq(pooledView.previewSupplyBalance(marketId, positionId), 0);
        assertEq(pooledView.previewDebtBalance(marketId, positionId), 0);

        assertEq(harness.getEncumberedForModule(positionKey, LOAN_POOL_ID, moduleId), 0);
        assertEq(harness.getEncumberedForModule(positionKey, COLLATERAL_POOL_ID, moduleId), 0);
        assertEq(harness.getPoolPrincipal(LOAN_POOL_ID, positionKey), 1_000);
        assertEq(harness.getPoolPrincipal(COLLATERAL_POOL_ID, positionKey), 1_000);
    }

    function _assertMarketCreated(Vm.Log[] memory logs, uint256 marketId, uint256 loanPoolId, uint256 collateralPoolId)
        internal
        pure
    {
        bytes32 sig = keccak256("IlmMarketCreated(uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) != marketId) continue;
            if (uint256(logs[i].topics[2]) != loanPoolId) continue;
            if (uint256(logs[i].topics[3]) != collateralPoolId) continue;
            return;
        }
        revert("IlmMarketCreated not found");
    }

    function _assertSupplyEvent(Vm.Log[] memory logs, uint256 marketId, bytes32 positionKey, uint256 amount, uint256 scaled)
        internal
        pure
    {
        bytes32 sig = keccak256("IlmSupply(uint256,bytes32,uint256,uint256)");
        _assertTwoIndexedTwoUint(logs, sig, marketId, positionKey, amount, scaled, "IlmSupply not found");
    }

    function _assertBorrowEvent(Vm.Log[] memory logs, uint256 marketId, bytes32 positionKey, uint256 amount, uint256 scaled)
        internal
        pure
    {
        bytes32 sig = keccak256("IlmBorrow(uint256,bytes32,uint256,uint256)");
        _assertTwoIndexedTwoUint(logs, sig, marketId, positionKey, amount, scaled, "IlmBorrow not found");
    }

    function _assertRepayEvent(Vm.Log[] memory logs, uint256 marketId, bytes32 positionKey, uint256 amount, uint256 scaled)
        internal
        pure
    {
        bytes32 sig = keccak256("IlmRepay(uint256,bytes32,uint256,uint256)");
        _assertTwoIndexedTwoUint(logs, sig, marketId, positionKey, amount, scaled, "IlmRepay not found");
    }

    function _assertWithdrawEvent(
        Vm.Log[] memory logs,
        uint256 marketId,
        bytes32 positionKey,
        uint256 amount,
        uint256 scaled
    ) internal pure {
        bytes32 sig = keccak256("IlmWithdraw(uint256,bytes32,uint256,uint256)");
        _assertTwoIndexedTwoUint(logs, sig, marketId, positionKey, amount, scaled, "IlmWithdraw not found");
    }

    function _assertTwoIndexedTwoUint(
        Vm.Log[] memory logs,
        bytes32 sig,
        uint256 marketId,
        bytes32 positionKey,
        uint256 a,
        uint256 b,
        string memory err
    ) internal pure {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) != marketId) continue;
            if (logs[i].topics[2] != positionKey) continue;
            (uint256 gotA, uint256 gotB) = abi.decode(logs[i].data, (uint256, uint256));
            if (gotA == a && gotB == b) return;
        }
        revert(err);
    }
}
