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
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MamCurveGasTest is Test {
    MamCurveGasHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);
    address internal treasury = address(0xC0FFEE);

    uint256 internal makerTokenId;
    bytes32 internal makerPositionKey;
    uint256 internal curveId;

    function setUp() public {
        harness = new MamCurveGasHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);
        harness.configurePositionNFT(address(nft));
        harness.setTreasury(treasury);

        makerTokenId = nft.mint(maker, 1);
        makerPositionKey = nft.getPositionKey(makerTokenId);

        uint256 principalA = 25e18;
        uint256 principalB = 25e18;
        harness.seedPool(1, address(tokenA), makerPositionKey, principalA, principalA);
        harness.seedPool(2, address(tokenB), makerPositionKey, principalB, principalB);
        harness.joinPool(makerPositionKey, 1);
        harness.joinPool(makerPositionKey, 2);

        MamTypes.CurveDescriptor memory desc = _makeDesc(7, uint64(block.timestamp), 2e18);

        vm.prank(maker);
        curveId = harness.createCurve(desc);
    }

    function _makeDesc(
        uint96 salt,
        uint64 startTime,
        uint128 maxVolume
    ) internal view returns (MamTypes.CurveDescriptor memory) {
        return MamTypes.CurveDescriptor({
            makerPositionKey: makerPositionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: maxVolume,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: startTime,
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: salt
        });
    }

    function _makeDescs(
        uint256 count,
        uint96 saltBase,
        uint64 startTime,
        uint128 maxVolume
    ) internal view returns (MamTypes.CurveDescriptor[] memory) {
        MamTypes.CurveDescriptor[] memory descs = new MamTypes.CurveDescriptor[](count);
        for (uint256 i = 0; i < count; i++) {
            descs[i] = _makeDesc(uint96(uint256(saltBase) + i), startTime, maxVolume);
        }
        return descs;
    }

    function _makeUpdateParams(
        uint256 count,
        uint64 startTimeBase
    ) internal pure returns (MamTypes.CurveUpdateParams[] memory) {
        MamTypes.CurveUpdateParams[] memory params = new MamTypes.CurveUpdateParams[](count);
        for (uint256 i = 0; i < count; i++) {
            params[i] = MamTypes.CurveUpdateParams({
                startPrice: uint128(3e18 + (i * 1e18)),
                endPrice: uint128(2e18 + (i * 1e18)),
                startTime: startTimeBase + uint64((i + 1) * 1 hours),
                duration: uint64(2 days + (i * 1 days))
            });
        }
        return params;
    }

    function testGasCreateCurve() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor memory desc = _makeDesc(8, uint64(block.timestamp + 1), 1e18);
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.createCurve(desc);
    }

    function testGasUpdateCurve() public {
        vm.pauseGasMetering();
        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 2 days
        });
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.updateCurve(curveId, params);
    }

    function testGasCancelCurve() public {
        vm.pauseGasMetering();
        vm.resumeGasMetering();
        vm.prank(maker);
        harness.cancelCurve(curveId);
    }

    function testGasExecuteCurveSwap() public {
        vm.pauseGasMetering();
        uint256 amountIn = 2e18;
        uint256 feeAmount = (amountIn * 100) / 10_000;
        tokenB.mint(taker, amountIn + feeAmount);
        vm.prank(taker);
        tokenB.approve(address(harness), amountIn + feeAmount);
        vm.resumeGasMetering();

        vm.prank(taker);
        harness.executeCurveSwap(
            curveId,
            amountIn,
            1e18,
            uint64(block.timestamp + 1 days),
            taker
        );
    }

    function testGasCreateCurvesBatch() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            2,
            11,
            uint64(block.timestamp + 10),
            1e18
        );
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.createCurvesBatch(descs);
    }

    function testGasUpdateCurvesBatch() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            2,
            21,
            uint64(block.timestamp + 10),
            1e18
        );

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        MamTypes.CurveUpdateParams[] memory params = _makeUpdateParams(
            2,
            uint64(block.timestamp)
        );

        uint256[] memory ids = new uint256[](2);
        ids[0] = firstId;
        ids[1] = firstId + 1;
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.updateCurvesBatch(ids, params);
    }

    function testGasCancelCurvesBatch() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            2,
            31,
            uint64(block.timestamp + 10),
            1e18
        );

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        uint256[] memory ids = new uint256[](2);
        ids[0] = firstId;
        ids[1] = firstId + 1;
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.cancelCurvesBatch(ids);
    }

    function testGasCreateCurvesBatch5() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            5,
            41,
            uint64(block.timestamp + 10),
            1e18
        );
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.createCurvesBatch(descs);
    }

    function testGasCreateCurvesBatch10() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            10,
            51,
            uint64(block.timestamp + 10),
            1e18
        );
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.createCurvesBatch(descs);
    }

    function testGasUpdateCurvesBatch5() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            5,
            61,
            uint64(block.timestamp + 10),
            1e18
        );

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        MamTypes.CurveUpdateParams[] memory params = _makeUpdateParams(
            5,
            uint64(block.timestamp)
        );

        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = firstId + i;
        }
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.updateCurvesBatch(ids, params);
    }

    function testGasUpdateCurvesBatch10() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            10,
            71,
            uint64(block.timestamp + 10),
            1e18
        );

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        MamTypes.CurveUpdateParams[] memory params = _makeUpdateParams(
            10,
            uint64(block.timestamp)
        );

        uint256[] memory ids = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            ids[i] = firstId + i;
        }
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.updateCurvesBatch(ids, params);
    }

    function testGasCancelCurvesBatch5() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            5,
            81,
            uint64(block.timestamp + 10),
            1e18
        );

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = firstId + i;
        }
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.cancelCurvesBatch(ids);
    }

    function testGasCancelCurvesBatch10() public {
        vm.pauseGasMetering();
        MamTypes.CurveDescriptor[] memory descs = _makeDescs(
            10,
            91,
            uint64(block.timestamp + 10),
            1e18
        );

        vm.prank(maker);
        uint256 firstId = harness.createCurvesBatch(descs);

        uint256[] memory ids = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            ids[i] = firstId + i;
        }
        vm.resumeGasMetering();

        vm.prank(maker);
        harness.cancelCurvesBatch(ids);
    }
}

contract MamCurveGasHarness is MamCurveCreationFacet, MamCurveManagementFacet, MamCurveExecutionFacet, MamCurveViewFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
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

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }
}
