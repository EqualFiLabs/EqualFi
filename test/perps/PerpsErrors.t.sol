// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    Perps_MarketNotFound,
    Perps_MarketAlreadyExists,
    Perps_AccountNotFound,
    Perps_Unauthorized,
    Perps_InvalidIntent,
    Perps_IntentCanceled,
    Perps_IntentExpired,
    Perps_BadSignature,
    Perps_NonceMismatch,
    Perps_NonceInvalidated,
    Perps_PriceStale,
    Perps_PriceOutOfBounds,
    Perps_RiskLimitExceeded,
    Perps_InsufficientMargin,
    Perps_InsufficientPerpsLiquidity,
    Perps_PositionHealthy,
    Perps_IncreasePaused,
    Perps_DecreasePaused,
    Perps_LiquidationPaused,
    Perps_SyncPaused,
    Perps_IsolationViolation
} from "../../src/perps/PerpsErrors.sol";

contract PerpsErrorsHarness {
    function revertMarketNotFound(bytes32 marketId) external pure {
        revert Perps_MarketNotFound(marketId);
    }

    function revertMarketAlreadyExists(bytes32 marketId) external pure {
        revert Perps_MarketAlreadyExists(marketId);
    }

    function revertAccountNotFound(bytes32 accountId) external pure {
        revert Perps_AccountNotFound(accountId);
    }

    function revertUnauthorized(bytes32 accountId, address caller) external pure {
        revert Perps_Unauthorized(accountId, caller);
    }

    function revertInvalidIntent() external pure {
        revert Perps_InvalidIntent();
    }

    function revertIntentCanceled(bytes32 intentHash) external pure {
        revert Perps_IntentCanceled(intentHash);
    }

    function revertIntentExpired(uint64 deadline, uint64 nowTs) external pure {
        revert Perps_IntentExpired(deadline, nowTs);
    }

    function revertBadSignature() external pure {
        revert Perps_BadSignature();
    }

    function revertNonceMismatch(uint64 expected, uint64 got) external pure {
        revert Perps_NonceMismatch(expected, got);
    }

    function revertNonceInvalidated(uint64 minValidNonce, uint64 intentNonce) external pure {
        revert Perps_NonceInvalidated(minValidNonce, intentNonce);
    }

    function revertPriceStale(uint256 updatedAt, uint256 maxStaleness) external pure {
        revert Perps_PriceStale(updatedAt, maxStaleness);
    }

    function revertPriceOutOfBounds() external pure {
        revert Perps_PriceOutOfBounds();
    }

    function revertRiskLimitExceeded() external pure {
        revert Perps_RiskLimitExceeded();
    }

    function revertInsufficientMargin(uint256 required, uint256 actual) external pure {
        revert Perps_InsufficientMargin(required, actual);
    }

    function revertInsufficientLiquidity(uint256 required, uint256 available) external pure {
        revert Perps_InsufficientPerpsLiquidity(required, available);
    }

    function revertPositionHealthy() external pure {
        revert Perps_PositionHealthy();
    }

    function revertIncreasePaused(bytes32 marketId) external pure {
        revert Perps_IncreasePaused(marketId);
    }

    function revertDecreasePaused(bytes32 marketId) external pure {
        revert Perps_DecreasePaused(marketId);
    }

    function revertLiquidationPaused(bytes32 marketId) external pure {
        revert Perps_LiquidationPaused(marketId);
    }

    function revertSyncPaused(bytes32 marketId) external pure {
        revert Perps_SyncPaused(marketId);
    }

    function revertIsolationViolation() external pure {
        revert Perps_IsolationViolation();
    }
}

contract PerpsErrorsTest is Test {
    PerpsErrorsHarness internal h;

    function setUp() public {
        h = new PerpsErrorsHarness();
    }

    function test_revertPayloads_identityAndAuthErrors() public {
        bytes32 marketId = keccak256("market");
        bytes32 accountId = keccak256("account");

        vm.expectRevert(abi.encodeWithSelector(Perps_MarketNotFound.selector, marketId));
        h.revertMarketNotFound(marketId);

        vm.expectRevert(abi.encodeWithSelector(Perps_MarketAlreadyExists.selector, marketId));
        h.revertMarketAlreadyExists(marketId);

        vm.expectRevert(abi.encodeWithSelector(Perps_AccountNotFound.selector, accountId));
        h.revertAccountNotFound(accountId);

        vm.expectRevert(abi.encodeWithSelector(Perps_Unauthorized.selector, accountId, address(this)));
        h.revertUnauthorized(accountId, address(this));
    }

    function test_revertPayloads_intentErrors() public {
        bytes32 intentHash = keccak256("intent");

        vm.expectRevert(abi.encodeWithSelector(Perps_InvalidIntent.selector));
        h.revertInvalidIntent();

        vm.expectRevert(abi.encodeWithSelector(Perps_IntentCanceled.selector, intentHash));
        h.revertIntentCanceled(intentHash);

        vm.expectRevert(abi.encodeWithSelector(Perps_IntentExpired.selector, uint64(10), uint64(11)));
        h.revertIntentExpired(10, 11);

        vm.expectRevert(abi.encodeWithSelector(Perps_BadSignature.selector));
        h.revertBadSignature();

        vm.expectRevert(abi.encodeWithSelector(Perps_NonceMismatch.selector, uint64(10), uint64(9)));
        h.revertNonceMismatch(10, 9);

        vm.expectRevert(abi.encodeWithSelector(Perps_NonceInvalidated.selector, uint64(100), uint64(90)));
        h.revertNonceInvalidated(100, 90);
    }

    function test_revertPayloads_riskOracleAndPauseErrors() public {
        bytes32 marketId = keccak256("paused-market");

        vm.expectRevert(abi.encodeWithSelector(Perps_PriceStale.selector, 100, 60));
        h.revertPriceStale(100, 60);

        vm.expectRevert(abi.encodeWithSelector(Perps_PriceOutOfBounds.selector));
        h.revertPriceOutOfBounds();

        vm.expectRevert(abi.encodeWithSelector(Perps_RiskLimitExceeded.selector));
        h.revertRiskLimitExceeded();

        vm.expectRevert(abi.encodeWithSelector(Perps_InsufficientMargin.selector, 200, 150));
        h.revertInsufficientMargin(200, 150);

        vm.expectRevert(abi.encodeWithSelector(Perps_InsufficientPerpsLiquidity.selector, 1_000, 500));
        h.revertInsufficientLiquidity(1_000, 500);

        vm.expectRevert(abi.encodeWithSelector(Perps_PositionHealthy.selector));
        h.revertPositionHealthy();

        vm.expectRevert(abi.encodeWithSelector(Perps_IncreasePaused.selector, marketId));
        h.revertIncreasePaused(marketId);

        vm.expectRevert(abi.encodeWithSelector(Perps_DecreasePaused.selector, marketId));
        h.revertDecreasePaused(marketId);

        vm.expectRevert(abi.encodeWithSelector(Perps_LiquidationPaused.selector, marketId));
        h.revertLiquidationPaused(marketId);

        vm.expectRevert(abi.encodeWithSelector(Perps_SyncPaused.selector, marketId));
        h.revertSyncPaused(marketId);

        vm.expectRevert(abi.encodeWithSelector(Perps_IsolationViolation.selector));
        h.revertIsolationViolation();
    }
}
