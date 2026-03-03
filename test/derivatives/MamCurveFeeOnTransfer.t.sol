// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../../src/EqualX/MamCurveExecutionFacet.sol";
import {MamCurveViewFacet} from "../../src/views/MamCurveViewFacet.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MamCurveFoTHarness is MamCurveCreationFacet, MamCurveManagementFacet, MamCurveExecutionFacet, MamCurveViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setMakerShareBps(uint16 shareBps) external {
        LibDerivativeStorage.derivativeStorage().config.mamMakerShareBps = shareBps;
    }

    function getMakerShareBps() external view returns (uint16) {
        return LibDerivativeStorage.derivativeStorage().config.mamMakerShareBps;
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
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getUserPrincipal(uint256 pid, bytes32 key) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[key];
    }

    function getTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }
}

contract MamCurveFeeOnTransferTest is Test {
    MamCurveFoTHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal baseToken;
    FeeOnTransferERC20 internal quoteToken;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal feeSink = address(0xFEE);

    function setUp() public {
        harness = new MamCurveFoTHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        baseToken = new MockERC20("Base", "B", 18, 0);
        quoteToken = new FeeOnTransferERC20("Quote", "Q", 18, 0, 500, feeSink); // 5%
        harness.configurePositionNFT(address(nft));
        harness.setTreasury(address(0));
        harness.setMakerShareBps(7000);
        vm.warp(1 days);
    }

    function _grossWithFee(uint256 netAmount) internal view returns (uint256) {
        uint256 feeBps = quoteToken.feeBps();
        return Math.mulDiv(netAmount, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function test_curveSwap_acceptsFoTQuoteWithGrossedMax() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(baseToken), positionKey, principalA, principalA);
        harness.seedPool(2, address(quoteToken), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(baseToken),
            tokenB: address(quoteToken),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 7,
            profileId: 1,
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 netQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 gross = _grossWithFee(netQuote);
        quoteToken.mint(taker, gross);
        vm.startPrank(taker);
        quoteToken.approve(address(harness), gross);

        uint256 sinkBefore = quoteToken.balanceOf(feeSink);
        uint256 out = harness.executeCurveSwap(curveId, amountIn, gross, 1e18, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();

        assertEq(out, 1e18, "base out");
        assertEq(baseToken.balanceOf(taker), 1e18, "taker received base");
        assertGt(quoteToken.balanceOf(feeSink), sinkBefore, "fee charged");
    }

    function test_curveSwap_overCapMax_preservesOutputAndAccounting() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 5e18;
        uint256 principalB = 5e18;
        harness.seedPool(1, address(baseToken), positionKey, principalA, principalA);
        harness.seedPool(2, address(quoteToken), positionKey, principalB, principalB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(baseToken),
            tokenB: address(quoteToken),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 8,
            profileId: 1,
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        uint256 amountIn = 2e18;
        uint256 netQuote = harness.previewCurveQuote(curveId, amountIn);
        uint256 gross = _grossWithFee(netQuote);
        uint256 overCapGross = gross + 1e18;
        quoteToken.mint(taker, overCapGross);

        uint256 makerQuoteBefore = harness.getUserPrincipal(2, positionKey);
        uint256 trackedBefore = harness.getTrackedBalance(2);
        uint256 sinkBefore = quoteToken.balanceOf(feeSink);

        vm.startPrank(taker);
        quoteToken.approve(address(harness), overCapGross);
        uint256 out = harness.executeCurveSwap(curveId, amountIn, overCapGross, 1e18, uint64(block.timestamp + 1 days), taker);
        vm.stopPrank();

        uint256 feeAmount = (amountIn * 100) / 10_000;
        uint256 makerFee = (feeAmount * harness.getMakerShareBps()) / 10_000;

        assertEq(out, 1e18, "base out");
        assertEq(baseToken.balanceOf(taker), 1e18, "taker received base");
        assertEq(
            harness.getUserPrincipal(2, positionKey),
            makerQuoteBefore + amountIn + makerFee,
            "maker accounting independent of over-cap max"
        );
        assertGt(harness.getTrackedBalance(2), trackedBefore, "tracked increased");
        assertGt(quoteToken.balanceOf(feeSink), sinkBefore, "FoT charged on transfer/refund path");
    }
}
