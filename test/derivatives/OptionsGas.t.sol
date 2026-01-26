// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
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
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract OptionsGasTest is Test {
    OptionsGasHarness internal harness;
    PositionNFT internal nft;
    OptionToken internal optionToken;
    MockERC20 internal underlying;
    MockERC20 internal strike;

    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);

    uint256 internal seriesId;
    uint256 internal makerTokenId;

    function setUp() public {
        harness = new OptionsGasHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        underlying = new MockERC20("Underlying", "UND", 18, 0);
        strike = new MockERC20("Strike", "STK", 18, 0);

        optionToken = new OptionToken("", address(this), address(harness));
        harness.setOptionTokenDirect(address(optionToken));
        harness.configurePositionNFT(address(nft));

        makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        uint256 principal = 10e18;
        harness.seedPool(1, address(underlying), positionKey, principal, principal);
        harness.seedPool(2, address(strike), positionKey, principal, principal);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function testGasCreateOptionSeries() public {
        vm.pauseGasMetering();
        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
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

        vm.resumeGasMetering();
        vm.prank(maker);
        harness.createOptionSeries(params);
    }

    function testGasExerciseOptions() public {
        vm.pauseGasMetering();
        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
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

        vm.prank(maker);
        seriesId = harness.createOptionSeries(params);

        uint256 strikeAmount = 2e18;
        strike.mint(holder, strikeAmount);
        vm.prank(holder);
        strike.approve(address(harness), strikeAmount);

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        vm.resumeGasMetering();
        vm.prank(holder);
        harness.exerciseOptions(seriesId, 1e18, holder);
    }
}

contract OptionsGasHarness is OptionsFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setOptionTokenDirect(address token) external {
        LibDerivativeStorage.derivativeStorage().optionToken = token;
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
