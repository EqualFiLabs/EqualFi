// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {AmmAuctionFacet, AmmAuction_Paused} from "../../src/EqualX/AmmAuctionFacet.sol";
import {OptionsFacet, Options_NotTokenHolder, Options_Paused} from "../../src/derivatives/OptionsFacet.sol";
import {FuturesFacet, Futures_NotTokenHolder, Futures_Paused} from "../../src/derivatives/FuturesFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Feature: position-nft-derivatives, Property 9: Creation Authorization
/// @notice Validates: Requirements 1.2, 15.1
/// @notice Feature: position-nft-derivatives, Property 10: Exercise Authorization
/// @notice Validates: Requirements 15.2
/// @notice Feature: position-nft-derivatives, Property 8: Reclaim Authorization
/// @notice Validates: Requirements 8.4, 11.4, 15.3
/// @notice Feature: position-nft-derivatives, Property 17: Pause Scope
/// @notice Validates: Requirements 15.4, 15.5
contract DerivativeAccessControlPropertyTest is Test {
    OptionsAccessHarness internal optionsHarness;
    FuturesAccessHarness internal futuresHarness;
    AmmAccessHarness internal ammHarness;
    PositionNFT internal nft;
    OptionToken internal optionToken;
    FuturesToken internal futuresToken;
    MockERC20 internal underlying;
    MockERC20 internal quote;

    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);
    address internal operator = address(0x0B0B);
    address internal attacker = address(0xBAD);

    function setUp() public {
        optionsHarness = new OptionsAccessHarness();
        futuresHarness = new FuturesAccessHarness();
        ammHarness = new AmmAccessHarness();
        optionsHarness.setContractOwner(address(this));
        futuresHarness.setContractOwner(address(this));
        ammHarness.setContractOwner(address(this));
        vm.warp(1);
        nft = new PositionNFT();
        nft.setMinter(address(this));
        optionsHarness.configurePositionNFT(address(nft));
        futuresHarness.configurePositionNFT(address(nft));
        ammHarness.configurePositionNFT(address(nft));
        optionToken = new OptionToken("", address(this), address(optionsHarness));
        futuresToken = new FuturesToken("", address(this), address(futuresHarness));
        optionsHarness.setOptionTokenHarness(address(optionToken));
        futuresHarness.setFuturesTokenHarness(address(futuresToken));
        optionsHarness.setEuropeanTolerance(100);
        futuresHarness.setEuropeanTolerance(100);
        futuresHarness.setGracePeriod(2 days);

        underlying = new MockERC20("Underlying", "UND", 18, 0);
        quote = new MockERC20("Quote", "QTE", 6, 0);
    }

    function testProperty_CreationAuthorization() public {
        uint256 makerTokenId = nft.mint(maker, 1);

        DerivativeTypes.CreateOptionSeriesParams memory optionParams = DerivativeTypes.CreateOptionSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: 2e18,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 1e18,
            isCall: true,
            isAmerican: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, attacker, makerTokenId));
        optionsHarness.createOptionSeries(optionParams);

        DerivativeTypes.CreateFuturesSeriesParams memory futuresParams = DerivativeTypes.CreateFuturesSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            quotePoolId: 2,
            forwardPrice: 2e18,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 1e18,
            isEuropean: false,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, attacker, makerTokenId));
        futuresHarness.createFuturesSeries(futuresParams);

        DerivativeTypes.CreateAuctionParams memory auctionParams = DerivativeTypes.CreateAuctionParams({
            positionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1e18,
            reserveB: 2e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, attacker, makerTokenId));
        ammHarness.createAuction(auctionParams);

        uint256 operatorTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(operatorTokenId);
        _seedPools(address(optionsHarness), positionKey, 1, 2, 1e24, 1e24);
        _seedPools(address(futuresHarness), positionKey, 1, 2, 1e24, 1e24);
        _seedPools(address(ammHarness), positionKey, 1, 2, 1e24, 1e24);
        vm.prank(maker);
        nft.setApprovalForAll(operator, true);

        vm.prank(operator);
        optionsHarness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: operatorTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(operator);
        futuresHarness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: operatorTokenId,
                underlyingPoolId: 1,
                quotePoolId: 2,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 1e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(operator);
        ammHarness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: operatorTokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 1e18,
                reserveB: 2e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );
    }

    function testProperty_ExerciseAuthorization() public {
        uint256 optionTokenId = nft.mint(maker, 1);
        bytes32 optionKey = nft.getPositionKey(optionTokenId);
        _seedPools(address(optionsHarness), optionKey, 1, 2, 1e24, 1e24);

        vm.prank(maker);
        uint256 optionSeriesId = optionsHarness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: optionTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, optionSeriesId, 1e18, "");

        uint256 strikeAmount = _quoteAmount(1e18, 2e18);
        quote.mint(holder, strikeAmount);
        vm.prank(holder);
        quote.approve(address(optionsHarness), strikeAmount);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Options_NotTokenHolder.selector, attacker, optionSeriesId));
        optionsHarness.exerciseOptionsFor(optionSeriesId, 1e18, holder, holder);

        vm.prank(holder);
        optionToken.setApprovalForAll(operator, true);

        vm.prank(operator);
        optionsHarness.exerciseOptionsFor(optionSeriesId, 1e18, holder, holder);

        uint256 futuresTokenId = nft.mint(maker, 1);
        bytes32 futuresKey = nft.getPositionKey(futuresTokenId);
        _seedPools(address(futuresHarness), futuresKey, 3, 4, 1e24, 1e24);

        vm.prank(maker);
        uint256 futuresSeriesId = futuresHarness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: futuresTokenId,
                underlyingPoolId: 3,
                quotePoolId: 4,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, futuresSeriesId, 1e18, "");

        uint256 quoteAmount = _quoteAmount(1e18, 2e18);
        quote.mint(holder, quoteAmount);
        vm.prank(holder);
        quote.approve(address(futuresHarness), quoteAmount);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Futures_NotTokenHolder.selector, attacker, futuresSeriesId));
        futuresHarness.settleFuturesFor(futuresSeriesId, 1e18, holder, holder);

        vm.prank(holder);
        futuresToken.setApprovalForAll(operator, true);

        vm.prank(operator);
        futuresHarness.settleFuturesFor(futuresSeriesId, 1e18, holder, holder);
    }

    function testProperty_ReclaimAuthorization() public {
        uint256 optionTokenId = nft.mint(maker, 1);
        bytes32 optionKey = nft.getPositionKey(optionTokenId);
        _seedPools(address(optionsHarness), optionKey, 1, 2, 1e24, 1e24);

        vm.prank(maker);
        uint256 optionSeriesId = optionsHarness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: optionTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.warp(block.timestamp + 2 days);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, attacker, optionTokenId));
        optionsHarness.reclaimOptions(optionSeriesId);

        vm.warp(10 days);
        uint64 futuresExpiry = uint64(11 days);
        uint256 futuresTokenId = nft.mint(maker, 1);
        bytes32 futuresKey = nft.getPositionKey(futuresTokenId);
        _seedPools(address(futuresHarness), futuresKey, 3, 4, 1e24, 1e24);

        vm.prank(maker);
        uint256 futuresSeriesId = futuresHarness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: futuresTokenId,
                underlyingPoolId: 3,
                quotePoolId: 4,
                forwardPrice: 2e18,
                expiry: futuresExpiry,
                totalSize: 1e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.warp(block.timestamp + 3 days);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, attacker, futuresTokenId));
        futuresHarness.reclaimFutures(futuresSeriesId);
    }

    function testProperty_PauseScope() public {
        uint256 optionTokenId = nft.mint(maker, 1);
        bytes32 optionKey = nft.getPositionKey(optionTokenId);
        _seedPools(address(optionsHarness), optionKey, 1, 2, 1e24, 1e24);

        vm.prank(maker);
        uint256 optionSeriesId = optionsHarness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: optionTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, optionSeriesId, 1e18, "");
        uint256 strikeAmount = _quoteAmount(1e18, 2e18);
        quote.mint(holder, strikeAmount);
        vm.prank(holder);
        quote.approve(address(optionsHarness), strikeAmount);

        uint256 futuresTokenId = nft.mint(maker, 1);
        bytes32 futuresKey = nft.getPositionKey(futuresTokenId);
        _seedPools(address(futuresHarness), futuresKey, 3, 4, 1e24, 1e24);

        vm.prank(maker);
        uint256 futuresSeriesId = futuresHarness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: futuresTokenId,
                underlyingPoolId: 3,
                quotePoolId: 4,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, futuresSeriesId, 1e18, "");
        uint256 quoteAmount = _quoteAmount(1e18, 2e18);
        quote.mint(holder, quoteAmount);
        vm.prank(holder);
        quote.approve(address(futuresHarness), quoteAmount);

        uint256 auctionTokenId = nft.mint(maker, 1);
        bytes32 auctionKey = nft.getPositionKey(auctionTokenId);
        _seedPools(address(ammHarness), auctionKey, 5, 6, 1e24, 1e24);

        vm.prank(maker);
        uint256 auctionId = ammHarness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: auctionTokenId,
                poolIdA: 5,
                poolIdB: 6,
                reserveA: 1e18,
                reserveB: 2e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        optionsHarness.setOptionsPaused(true);
        futuresHarness.setFuturesPaused(true);
        ammHarness.setAmmPaused(true);

        vm.expectRevert(abi.encodeWithSelector(Options_Paused.selector));
        optionsHarness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: optionTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.expectRevert(abi.encodeWithSelector(Futures_Paused.selector));
        futuresHarness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: futuresTokenId,
                underlyingPoolId: 3,
                quotePoolId: 4,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.expectRevert(abi.encodeWithSelector(AmmAuction_Paused.selector));
        ammHarness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: auctionTokenId,
                poolIdA: 5,
                poolIdB: 6,
                reserveA: 1e18,
                reserveB: 2e18,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        vm.prank(holder);
        optionsHarness.exerciseOptions(optionSeriesId, 1e18, holder);

        vm.prank(holder);
        futuresHarness.settleFutures(futuresSeriesId, 1e18, holder);

        vm.warp(block.timestamp + 2 days);
        ammHarness.finalizeAuction(auctionId);
    }

    function _seedPools(
        address seeder,
        bytes32 positionKey,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 principal,
        uint256 tracked
    ) internal {
        PoolSeeder typedSeeder = PoolSeeder(seeder);
        typedSeeder.seedPool(poolIdA, address(underlying), positionKey, principal, tracked);
        typedSeeder.seedPool(poolIdB, address(quote), positionKey, principal, tracked);
        typedSeeder.joinPool(positionKey, poolIdA);
        typedSeeder.joinPool(positionKey, poolIdB);
    }

    function _quoteAmount(uint256 amount, uint256 forwardPrice) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(underlying.decimals());
        uint256 quoteScale = 10 ** uint256(quote.decimals());
        uint256 normalizedUnderlying = Math.mulDiv(amount, forwardPrice, underlyingScale);
        return Math.mulDiv(normalizedUnderlying, quoteScale, 1e18);
    }
}

interface PoolSeeder {
    function seedPool(uint256 pid, address asset, bytes32 positionKey, uint256 principal, uint256 tracked) external;
    function joinPool(bytes32 positionKey, uint256 pid) external;
}

contract OptionsAccessHarness is OptionsFacet {
    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

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
        address asset,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(asset).mint(address(this), tracked);
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
}

contract FuturesAccessHarness is FuturesFacet {
    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setFuturesTokenHarness(address token) external {
        LibDerivativeStorage.derivativeStorage().futuresToken = token;
    }

    function setEuropeanTolerance(uint64 tolerance) external {
        LibDerivativeStorage.derivativeStorage().config.europeanToleranceSeconds = tolerance;
    }

    function setGracePeriod(uint64 gracePeriod) external {
        LibDerivativeStorage.derivativeStorage().config.defaultGracePeriodSeconds = gracePeriod;
    }

    function seedPool(
        uint256 pid,
        address asset,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(asset).mint(address(this), tracked);
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
}

contract AmmAccessHarness is AmmAuctionFacet {
    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function seedPool(
        uint256 pid,
        address asset,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(asset).mint(address(this), tracked);
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
}
