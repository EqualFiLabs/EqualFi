// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {
    OptionsFacet,
    Options_ExerciseWindowClosed,
    Options_InsufficientBalance
} from "../../src/derivatives/OptionsFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

/// @notice Feature: position-nft-derivatives, Property 4: Full collateralization invariant (options)
/// @notice Validates: Requirements 12.2, 12.3, 12.4
/// forge-config: default.fuzz.runs = 100
contract OptionsFacetPropertyTest is Test {
    OptionsHarness internal harness;
    PositionNFT internal nft;
    OptionToken internal optionToken;
    MockERC20 internal underlying;
    MockERC20 internal strike;

    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);

    function setUp() public {
        harness = new OptionsHarness();
        vm.warp(1);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));
        optionToken = new OptionToken("", address(this), address(harness));
        harness.setOptionTokenHarness(address(optionToken));
        harness.setEuropeanTolerance(100);

        underlying = new MockERC20("Underlying", "UND", 18, 0);
        strike = new MockERC20("Strike", "STK", 6, 0);
    }

    function testProperty_FullCollateralizationInvariant(
        uint96 totalSize,
        uint96 exerciseAmount,
        bool isCall
    ) public {
        totalSize = uint96(bound(totalSize, 1e12, 1e24));
        exerciseAmount = uint96(bound(exerciseAmount, 0, totalSize));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 strikePrice = 2e18;
        uint256 requiredStrike = _strikeAmount(totalSize, strikePrice);

        uint256 underlyingPrincipal = totalSize + 1e6;
        uint256 strikePrincipal = requiredStrike + 1e6;
        harness.seedPool(1, address(underlying), positionKey, underlyingPrincipal, underlyingPrincipal);
        harness.seedPool(2, address(strike), positionKey, strikePrincipal, strikePrincipal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: strikePrice,
            expiry: uint64(block.timestamp + 7 days),
            totalSize: totalSize,
            isCall: isCall,
            isAmerican: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(params);

        if (exerciseAmount > 0 && _strikeAmount(exerciseAmount, strikePrice) == 0) {
            exerciseAmount = uint96(bound(exerciseAmount, 1e12, totalSize));
        }

        if (exerciseAmount > 0) {
            vm.prank(maker);
            optionToken.safeTransferFrom(maker, holder, seriesId, exerciseAmount, "");

            if (isCall) {
                uint256 strikeAmount = _strikeAmount(exerciseAmount, strikePrice);
                strike.mint(holder, strikeAmount);
                vm.prank(holder);
                strike.approve(address(harness), strikeAmount);
            } else {
                underlying.mint(holder, exerciseAmount);
                vm.prank(holder);
                underlying.approve(address(harness), exerciseAmount);
            }

            vm.prank(holder);
            harness.exerciseOptions(seriesId, exerciseAmount, holder);
        }

        DerivativeTypes.OptionSeries memory series = harness.getOptionSeries(seriesId);
        uint256 expectedRemaining = totalSize - exerciseAmount;
        uint256 initialLocked = isCall ? totalSize : _strikeAmount(totalSize, strikePrice);
        uint256 exercisedLocked = isCall ? exerciseAmount : _strikeAmount(exerciseAmount, strikePrice);
        uint256 expectedLocked = initialLocked - exercisedLocked;

        uint256 poolId = isCall ? 1 : 2;
        uint256 locked = harness.getLocked(positionKey, poolId);

        assertEq(series.remaining, expectedRemaining, "remaining tracks exercised size");
        assertEq(series.collateralLocked, expectedLocked, "series lock tracks remaining");
        assertEq(locked, expectedLocked, "directLockedPrincipal matches remaining");
    }

    /// @notice Property: European style window enforcement
    /// @notice Validates: Requirements 7.5, 10.4
    function testProperty_EuropeanStyleWindowEnforcement() public {
        vm.warp(1);
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalSize = 1e18;
        uint256 strikePrice = 2e18;
        uint256 requiredStrike = _strikeAmount(totalSize, strikePrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(strike), positionKey, requiredStrike + 1e6, requiredStrike + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 expiry = uint64(block.timestamp + 1 days);
        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: strikePrice,
            expiry: expiry,
            totalSize: totalSize,
            isCall: true,
            isAmerican: false,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(params);

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, totalSize, "");

        uint256 strikeAmount = _strikeAmount(totalSize, strikePrice);
        strike.mint(holder, strikeAmount);
        vm.prank(holder);
        strike.approve(address(harness), strikeAmount);

        vm.warp(expiry - 101);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(Options_ExerciseWindowClosed.selector, seriesId));
        harness.exerciseOptions(seriesId, totalSize, holder);

        vm.warp(expiry);
        vm.prank(holder);
        harness.exerciseOptions(seriesId, totalSize, holder);

        uint256 makerTokenIdLate = nft.mint(maker, 1);
        bytes32 lateKey = nft.getPositionKey(makerTokenIdLate);
        harness.seedPool(1, address(underlying), lateKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(strike), lateKey, requiredStrike + 1e6, requiredStrike + 1e6);
        harness.joinPool(lateKey, 1);
        harness.joinPool(lateKey, 2);

        uint64 expiryLate = expiry + uint64(1 days);
        vm.prank(maker);
        uint256 lateSeriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: makerTokenIdLate,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: strikePrice,
                expiry: expiryLate,
                totalSize: totalSize,
                isCall: true,
                isAmerican: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );
        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, lateSeriesId, totalSize, "");
        strike.mint(holder, strikeAmount);
        vm.prank(holder);
        strike.approve(address(harness), strikeAmount);

        vm.warp(expiryLate + 101);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(Options_ExerciseWindowClosed.selector, lateSeriesId));
        harness.exerciseOptions(lateSeriesId, totalSize, holder);
    }

    /// @notice Property: American style timing
    /// @notice Validates: Requirements 7.4, 10.5
    function testProperty_AmericanStyleTiming() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalSize = 1e18;
        uint256 strikePrice = 2e18;
        uint256 requiredStrike = _strikeAmount(totalSize, strikePrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(strike), positionKey, requiredStrike + 1e6, requiredStrike + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 expiry = uint64(block.timestamp + 1 days);
        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: strikePrice,
            expiry: expiry,
            totalSize: totalSize,
            isCall: false,
            isAmerican: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(params);

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, totalSize, "");

        underlying.mint(holder, totalSize);
        vm.prank(holder);
        underlying.approve(address(harness), totalSize);

        vm.prank(holder);
        harness.exerciseOptions(seriesId, totalSize, holder);

        uint256 makerTokenIdLate = nft.mint(maker, 1);
        bytes32 lateKey = nft.getPositionKey(makerTokenIdLate);
        harness.seedPool(1, address(underlying), lateKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(strike), lateKey, requiredStrike + 1e6, requiredStrike + 1e6);
        harness.joinPool(lateKey, 1);
        harness.joinPool(lateKey, 2);

        uint64 expiryLate = uint64(block.timestamp + 1 days);
        vm.prank(maker);
        uint256 lateSeriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: makerTokenIdLate,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: strikePrice,
                expiry: expiryLate,
                totalSize: totalSize,
                isCall: false,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );
        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, lateSeriesId, totalSize, "");
        underlying.mint(holder, totalSize);
        vm.prank(holder);
        underlying.approve(address(harness), totalSize);

        vm.warp(expiryLate + 1);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(Options_ExerciseWindowClosed.selector, lateSeriesId));
        harness.exerciseOptions(lateSeriesId, totalSize, holder);
    }

    /// @notice Property: token supply consistency
    /// @notice Validates: Requirements 6.4, 7.1, 9.3, 10.1
    function testProperty_TokenSupplyConsistency(uint96 totalSize, uint96 exerciseAmount) public {
        totalSize = uint96(bound(totalSize, 1e12, 1e24));
        exerciseAmount = uint96(bound(exerciseAmount, 0, totalSize));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 strikePrice = 2e18;
        uint256 requiredStrike = _strikeAmount(totalSize, strikePrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(strike), positionKey, requiredStrike + 1e6, requiredStrike + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: strikePrice,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: totalSize,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        if (exerciseAmount > 0 && _strikeAmount(exerciseAmount, strikePrice) == 0) {
            exerciseAmount = uint96(bound(exerciseAmount, 1e12, totalSize));
        }

        if (exerciseAmount > 0) {
            vm.prank(maker);
            optionToken.safeTransferFrom(maker, holder, seriesId, exerciseAmount, "");
            uint256 strikeAmount = _strikeAmount(exerciseAmount, strikePrice);
            strike.mint(holder, strikeAmount);
            vm.prank(holder);
            strike.approve(address(harness), strikeAmount);
            vm.prank(holder);
            harness.exerciseOptions(seriesId, exerciseAmount, holder);
        }

        DerivativeTypes.OptionSeries memory series = harness.getOptionSeries(seriesId);
        uint256 supply = optionToken.balanceOf(maker, seriesId) + optionToken.balanceOf(holder, seriesId);
        assertEq(supply, series.remaining, "erc1155 supply matches series remaining");
    }

    /// @notice Property: reclaim burns remaining supply
    /// @notice Validates: Requirements 8.2
    function testProperty_ReclaimBurnRequirement() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 totalSize = 1e18;
        uint256 strikePrice = 2e18;
        uint256 requiredStrike = _strikeAmount(totalSize, strikePrice);

        harness.seedPool(1, address(underlying), positionKey, totalSize + 1e6, totalSize + 1e6);
        harness.seedPool(2, address(strike), positionKey, requiredStrike + 1e6, requiredStrike + 1e6);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: strikePrice,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: totalSize,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, totalSize / 2, "");

        vm.warp(block.timestamp + 2 days);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Options_InsufficientBalance.selector, maker, totalSize, totalSize / 2));
        harness.reclaimOptions(seriesId);

        vm.prank(holder);
        optionToken.safeTransferFrom(holder, maker, seriesId, totalSize / 2, "");
        vm.prank(maker);
        harness.reclaimOptions(seriesId);

        assertEq(optionToken.balanceOf(maker, seriesId), 0, "reclaim burns remaining supply");
        assertEq(harness.getLocked(positionKey, 1), 0, "collateral unlocked");
    }

    function _strikeAmount(uint256 amount, uint256 strikePrice) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(underlying.decimals());
        uint256 strikeScale = 10 ** uint256(strike.decimals());
        uint256 normalizedUnderlying = Math.mulDiv(amount, strikePrice, underlyingScale);
        return Math.mulDiv(normalizedUnderlying, strikeScale, 1e18);
    }
}

contract OptionsHarness is OptionsFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setOptionTokenHarness(address token) external {
        LibDerivativeStorage.derivativeStorage().optionToken = token;
    }

    function setEuropeanTolerance(uint64 tolerance) external {
        LibDerivativeStorage.derivativeStorage().config.europeanToleranceSeconds = tolerance;
    }

    function seedPool(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(underlying).mint(address(this), tracked);
        }
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibFeeIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }
}
