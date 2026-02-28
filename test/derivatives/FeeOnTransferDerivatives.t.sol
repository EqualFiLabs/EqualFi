// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../../src/derivatives/FuturesFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OptionsFoTHarness is OptionsFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setOptionTokenDirect(address token) external {
        LibDerivativeStorage.derivativeStorage().optionToken = token;
    }

    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint256 tracked)
        external
    {
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

    function getPrincipal(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

contract FuturesFoTHarness is FuturesFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setFuturesTokenDirect(address token) external {
        LibDerivativeStorage.derivativeStorage().futuresToken = token;
    }

    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint256 tracked)
        external
    {
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

    function getPrincipal(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

contract FeeOnTransferDerivativesTest is Test {
    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);
    address internal feeSink = address(0xFEE);

    function _grossWithFee(uint256 netAmount, uint16 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(netAmount, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function test_optionsExercise_acceptsFoTStrikeWithGrossedMax() public {
        OptionsFoTHarness harness = new OptionsFoTHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        MockERC20 underlying = new MockERC20("Underlying", "UND", 18, 0);
        FeeOnTransferERC20 strike = new FeeOnTransferERC20("Strike", "STK", 18, 0, 500, feeSink); // 5%

        OptionToken optionToken = new OptionToken("", address(this), address(harness));
        harness.setOptionTokenDirect(address(optionToken));
        harness.configurePositionNFT(address(nft));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10e18;
        harness.seedPool(1, address(underlying), positionKey, principal, principal);
        harness.seedPool(2, address(strike), positionKey, principal, principal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: 2e18,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 1e18,
            contractSize: 1,
            isCall: true,
            isAmerican: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(params);

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 payment = harness.previewExercisePayment(seriesId, 1e18);
        uint256 gross = _grossWithFee(payment, strike.feeBps());
        strike.mint(holder, gross);
        vm.prank(holder);
        strike.approve(address(harness), gross);

        uint256 sinkBefore = strike.balanceOf(feeSink);
        vm.prank(holder);
        harness.exerciseOptions(seriesId, 1e18, holder, gross, 1e18);

        assertEq(underlying.balanceOf(holder), 1e18, "underlying paid out");
        assertGt(strike.balanceOf(feeSink), sinkBefore, "fee charged");
    }

    function test_optionsExercise_capsMakerCreditWhenMaxExceedsRequired() public {
        OptionsFoTHarness harness = new OptionsFoTHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        MockERC20 underlying = new MockERC20("Underlying", "UND", 18, 0);
        FeeOnTransferERC20 strike = new FeeOnTransferERC20("Strike", "STK", 18, 0, 500, feeSink); // 5%

        OptionToken optionToken = new OptionToken("", address(this), address(harness));
        harness.setOptionTokenDirect(address(optionToken));
        harness.configurePositionNFT(address(nft));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10e18;
        harness.seedPool(1, address(underlying), positionKey, principal, principal);
        harness.seedPool(2, address(strike), positionKey, principal, principal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 1e18,
                contractSize: 1,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 payment = harness.previewExercisePayment(seriesId, 1e18);
        uint256 gross = _grossWithFee(payment + (payment / 4), strike.feeBps());
        strike.mint(holder, gross);
        vm.prank(holder);
        strike.approve(address(harness), gross);
        uint256 makerStrikeBefore = harness.getPrincipal(positionKey, 2);

        vm.prank(holder);
        harness.exerciseOptions(seriesId, 1e18, holder, gross, 1e18);

        assertEq(harness.getPrincipal(positionKey, 2) - makerStrikeBefore, payment, "maker credit capped at required");
    }

    function test_futuresSettle_acceptsFoTQuoteWithGrossedMax() public {
        FuturesFoTHarness harness = new FuturesFoTHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        MockERC20 underlying = new MockERC20("Underlying", "UND", 18, 0);
        FeeOnTransferERC20 quote = new FeeOnTransferERC20("Quote", "QTE", 18, 0, 500, feeSink); // 5%

        FuturesToken futuresToken = new FuturesToken("", address(this), address(harness));
        harness.setFuturesTokenDirect(address(futuresToken));
        harness.configurePositionNFT(address(nft));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10e18;
        harness.seedPool(1, address(underlying), positionKey, principal, principal);
        harness.seedPool(2, address(quote), positionKey, principal, principal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 expiry = uint64(block.timestamp + 1 days);
        DerivativeTypes.CreateFuturesSeriesParams memory params = DerivativeTypes.CreateFuturesSeriesParams({
            positionId: makerTokenId,
            underlyingPoolId: 1,
            quotePoolId: 2,
            forwardPrice: 2e18,
            expiry: expiry,
            totalSize: 1e18,
            contractSize: 1,
            isEuropean: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(maker);
        uint256 seriesId = harness.createFuturesSeries(params);

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 payment = harness.previewSettlePayment(seriesId, 1e18);
        uint256 gross = _grossWithFee(payment, quote.feeBps());
        quote.mint(holder, gross);
        vm.prank(holder);
        quote.approve(address(harness), gross);

        uint256 sinkBefore = quote.balanceOf(feeSink);
        vm.warp(expiry);
        vm.prank(holder);
        harness.settleFutures(seriesId, 1e18, holder, gross, 1e18);

        assertEq(underlying.balanceOf(holder), 1e18, "underlying paid out");
        assertGt(quote.balanceOf(feeSink), sinkBefore, "fee charged");
    }

    function test_futuresSettle_capsMakerCreditWhenMaxExceedsRequired() public {
        FuturesFoTHarness harness = new FuturesFoTHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        MockERC20 underlying = new MockERC20("Underlying", "UND", 18, 0);
        FeeOnTransferERC20 quote = new FeeOnTransferERC20("Quote", "QTE", 18, 0, 500, feeSink); // 5%

        FuturesToken futuresToken = new FuturesToken("", address(this), address(harness));
        harness.setFuturesTokenDirect(address(futuresToken));
        harness.configurePositionNFT(address(nft));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10e18;
        harness.seedPool(1, address(underlying), positionKey, principal, principal);
        harness.seedPool(2, address(quote), positionKey, principal, principal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(maker);
        uint256 seriesId = harness.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: makerTokenId,
                underlyingPoolId: 1,
                quotePoolId: 2,
                forwardPrice: 2e18,
                expiry: expiry,
                totalSize: 1e18,
                contractSize: 1,
                isEuropean: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 payment = harness.previewSettlePayment(seriesId, 1e18);
        uint256 gross = _grossWithFee(payment + (payment / 4), quote.feeBps());
        quote.mint(holder, gross);
        vm.prank(holder);
        quote.approve(address(harness), gross);
        uint256 makerQuoteBefore = harness.getPrincipal(positionKey, 2);

        vm.warp(expiry);
        vm.prank(holder);
        harness.settleFutures(seriesId, 1e18, holder, gross, 1e18);

        assertEq(harness.getPrincipal(positionKey, 2) - makerQuoteBefore, payment, "maker credit capped at required");
    }
}
