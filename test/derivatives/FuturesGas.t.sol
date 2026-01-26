// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

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
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FuturesGasTest is Test {
    FuturesGasHarness internal harness;
    PositionNFT internal nft;
    FuturesToken internal futuresToken;
    MockERC20 internal underlying;
    MockERC20 internal quote;

    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);

    uint256 internal seriesId;
    uint256 internal makerTokenId;

    function setUp() public {
        harness = new FuturesGasHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        quote = new MockERC20("Quote", "QTE", 18, 0);

        futuresToken = new FuturesToken("", address(this), address(harness));
        harness.setFuturesTokenDirect(address(futuresToken));
        harness.configurePositionNFT(address(nft));

        makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10e18;
        harness.seedPool(1, address(underlying), positionKey, principal, principal);
        harness.seedPool(2, address(quote), positionKey, principal, principal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function testGasCreateFuturesSeries() public {
        vm.pauseGasMetering();
        DerivativeTypes.CreateFuturesSeriesParams memory params = DerivativeTypes.CreateFuturesSeriesParams({
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

        vm.resumeGasMetering();
        vm.prank(maker);
        harness.createFuturesSeries(params);
    }

    function testGasSettleFutures() public {
        vm.pauseGasMetering();
        DerivativeTypes.CreateFuturesSeriesParams memory params = DerivativeTypes.CreateFuturesSeriesParams({
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

        vm.prank(maker);
        seriesId = harness.createFuturesSeries(params);

        uint256 quoteAmount = 2e18;
        quote.mint(holder, quoteAmount);
        vm.prank(holder);
        quote.approve(address(harness), quoteAmount);

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        vm.resumeGasMetering();
        vm.prank(holder);
        harness.settleFutures(seriesId, 1e18, holder);
    }
}

contract FuturesGasHarness is FuturesFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setFuturesTokenDirect(address token) external {
        LibDerivativeStorage.derivativeStorage().futuresToken = token;
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
}
