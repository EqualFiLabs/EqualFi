// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../../src/derivatives/FuturesFacet.sol";
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

/// @notice Feature: position-nft-derivatives, Property 3: Collateral Unlock on Finalization
/// @notice Validates: Requirements 2.5, 5.2, 7.6, 8.2, 10.6, 11.2
contract DerivativeCollateralUnlockPropertyTest is Test {
    OptionsUnlockHarness internal optionsHarness;
    FuturesUnlockHarness internal futuresHarness;
    AmmUnlockHarness internal ammHarness;
    PositionNFT internal nft;
    OptionToken internal optionToken;
    FuturesToken internal futuresToken;
    MockERC20 internal underlying;
    MockERC20 internal quote;

    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);

    function setUp() public {
        optionsHarness = new OptionsUnlockHarness();
        futuresHarness = new FuturesUnlockHarness();
        ammHarness = new AmmUnlockHarness();

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

    function testProperty_CollateralUnlockOnFinalization() public {
        _optionsUnlocksCollateral();
        _futuresUnlocksCollateral();
        _ammUnlocksReserves();
    }

    function _optionsUnlocksCollateral() internal {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(tokenId);
        optionsHarness.seedPool(1, address(underlying), positionKey, 2e18, 2e18);
        optionsHarness.seedPool(2, address(quote), positionKey, 4e18, 4e18);
        optionsHarness.joinPool(positionKey, 1);
        optionsHarness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 seriesId = optionsHarness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: tokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 2e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        assertEq(optionsHarness.getLocked(positionKey, 1), 2e18, "options locked");

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");
        uint256 strikeAmount = _quoteAmount(1e18, 2e18);
        quote.mint(holder, strikeAmount);
        vm.prank(holder);
        quote.approve(address(optionsHarness), strikeAmount);
        vm.prank(holder);
        optionsHarness.exerciseOptions(seriesId, 1e18, holder);

        assertEq(optionsHarness.getLocked(positionKey, 1), 1e18, "options unlock on exercise");

        vm.warp(block.timestamp + 8 days);
        vm.prank(maker);
        optionsHarness.reclaimOptions(seriesId);
        assertEq(optionsHarness.getLocked(positionKey, 1), 0, "options unlock on reclaim");
    }

    function _futuresUnlocksCollateral() internal {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(tokenId);
        futuresHarness.seedPool(3, address(underlying), positionKey, 2e18, 2e18);
        futuresHarness.seedPool(4, address(quote), positionKey, 4e18, 4e18);
        futuresHarness.joinPool(positionKey, 3);
        futuresHarness.joinPool(positionKey, 4);

        vm.prank(maker);
        uint256 seriesId = futuresHarness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: tokenId,
                underlyingPoolId: 3,
                quotePoolId: 4,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 30 days),
                totalSize: 2e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        assertEq(futuresHarness.getLocked(positionKey, 3), 2e18, "futures locked");

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");
        uint256 quoteAmount = _quoteAmount(1e18, 2e18);
        quote.mint(holder, quoteAmount);
        vm.prank(holder);
        quote.approve(address(futuresHarness), quoteAmount);
        vm.prank(holder);
        futuresHarness.settleFutures(seriesId, 1e18, holder);

        assertEq(futuresHarness.getLocked(positionKey, 3), 1e18, "futures unlock on settlement");

        uint64 graceUnlockTime = futuresHarness.getGraceUnlockTime(seriesId);
        vm.warp(graceUnlockTime);
        vm.prank(maker);
        futuresHarness.reclaimFutures(seriesId);
        assertEq(futuresHarness.getLocked(positionKey, 3), 0, "futures unlock on reclaim");
    }

    function _ammUnlocksReserves() internal {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(tokenId);
        ammHarness.seedPool(5, address(underlying), positionKey, 5e18, 5e18);
        ammHarness.seedPool(6, address(quote), positionKey, 5e18, 5e18);
        ammHarness.joinPool(positionKey, 5);
        ammHarness.joinPool(positionKey, 6);

        vm.prank(maker);
        uint256 auctionId = ammHarness.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: tokenId,
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

        assertEq(ammHarness.getLent(positionKey, 5), 1e18, "amm reserve A locked");
        assertEq(ammHarness.getLent(positionKey, 6), 2e18, "amm reserve B locked");

        vm.warp(block.timestamp + 2 days);
        ammHarness.finalizeAuction(auctionId);

        assertEq(ammHarness.getLent(positionKey, 5), 0, "amm reserve A unlocked");
        assertEq(ammHarness.getLent(positionKey, 6), 0, "amm reserve B unlocked");
    }

    function _quoteAmount(uint256 amount, uint256 forwardPrice) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(underlying.decimals());
        uint256 quoteScale = 10 ** uint256(quote.decimals());
        uint256 normalizedUnderlying = Math.mulDiv(amount, forwardPrice, underlyingScale);
        return Math.mulDiv(normalizedUnderlying, quoteScale, 1e18);
    }
}

contract OptionsUnlockHarness is OptionsFacet {
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

    function getLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }
}

contract FuturesUnlockHarness is FuturesFacet {
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

    function getLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }
}

contract AmmUnlockHarness is AmmAuctionFacet {
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

    function getLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }
}
