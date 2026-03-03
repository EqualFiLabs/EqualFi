// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {MamCurveCreationFacet} from "src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "src/EqualX/MamCurveExecutionFacet.sol";
import {MamTypes} from "src/libraries/MamTypes.sol";
import {LibDerivativeStorage} from "src/libraries/LibDerivativeStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {Types} from "src/libraries/Types.sol";

contract MamCurveSnapshotHarness is MamCurveCreationFacet, MamCurveManagementFacet, MamCurveExecutionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setOwner(address owner_) external {
        LibDiamond.diamondStorage().contractOwner = owner_;
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
        if (tracked > 0 && underlying != address(0)) {
            MockERC20(underlying).mint(address(this), tracked);
        }
        if (p.feeIndex == 0) p.feeIndex = LibFeeIndex.INDEX_SCALE;
        if (p.maintenanceIndex == 0) p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        if (p.activeCreditIndex == 0) p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getStoredCurve(uint256 curveId) external view returns (MamTypes.StoredCurve memory) {
        return LibDerivativeStorage.derivativeStorage().curves[curveId];
    }
}

contract MamCurveSnapshotPackedEventTest is Test {
    event CurveSnapshotPackedV1(
        uint256 indexed curveId,
        bytes32 indexed makerPositionKey,
        bytes32 indexed pairKey,
        uint256 metaWord,
        uint256 priceWord,
        uint256 volumeWord,
        address profile,
        bytes32 profileParams,
        bytes32 commitment
    );

    uint8 internal constant STATUS_CREATED = 1;
    uint8 internal constant STATUS_UPDATED = 2;
    uint8 internal constant STATUS_FILLED = 3;
    uint8 internal constant STATUS_CANCELLED = 4;
    uint8 internal constant STATUS_EXPIRED = 5;
    uint8 internal constant PACKING_VERSION = 1;

    bytes32 internal constant SNAPSHOT_SIG =
        keccak256("CurveSnapshotPackedV1(uint256,bytes32,bytes32,uint256,uint256,uint256,address,bytes32,bytes32)");

    struct Snapshot {
        uint256 curveId;
        bytes32 makerPositionKey;
        bytes32 pairKey;
        uint256 metaWord;
        uint256 priceWord;
        uint256 volumeWord;
        address profile;
        bytes32 profileParams;
        bytes32 commitment;
    }

    MamCurveSnapshotHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    function setUp() public {
        harness = new MamCurveSnapshotHarness();
        harness.setOwner(address(this));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        vm.warp(1 days);
    }

    function test_curveSnapshotPackedCreateLayoutFixture() public {
        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(2e18, 1e18, uint64(block.timestamp), 1 days, 2e18, 100, 11);

        vm.recordLogs();
        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        Snapshot memory s = _snapshotFromLogs(vm.getRecordedLogs());
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);

        assertEq(s.curveId, curveId, "curveId");
        assertEq(s.makerPositionKey, desc.makerPositionKey, "makerPositionKey");
        assertEq(s.pairKey, _pairKey(desc.tokenA, desc.tokenB), "pairKey");

        uint256 expectedMeta = _packMeta(
            desc.feeRateBps,
            curve.generation,
            desc.startTime,
            desc.duration,
            true,
            desc.priceIsQuotePerBase,
            STATUS_CREATED,
            PACKING_VERSION
        );
        uint256 expectedPrice = _packPrice(desc.startPrice, desc.endPrice);
        uint256 expectedVolume = _packVolume(desc.maxVolume, curve.remainingVolume);

        assertEq(s.metaWord, expectedMeta, "metaWord");
        assertEq(s.priceWord, expectedPrice, "priceWord");
        assertEq(s.volumeWord, expectedVolume, "volumeWord");
        assertEq(s.profile, desc.profile, "profile");
        assertEq(s.profileParams, desc.profileParams, "profileParams");
        assertEq(s.commitment, curve.commitment, "commitment");

        _assertMetaFields(s.metaWord, desc.feeRateBps, curve.generation, desc.startTime, desc.duration, true, true, STATUS_CREATED, 1);
    }

    function test_curveSnapshotPackedUpdatePayload() public {
        (MamTypes.CurveDescriptor memory desc, uint256 curveId) =
            _createCurve(2e18, 1e18, uint64(block.timestamp), 1 days, 2e18, 100, 12);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 2 days,
            updateProfile: false,
            profile: address(0),
            updateProfileParams: false,
            profileParams: bytes32(0)
        });

        vm.recordLogs();
        vm.prank(maker);
        harness.updateCurve(curveId, params);

        Snapshot memory s = _snapshotFromLogs(vm.getRecordedLogs());
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);

        assertEq(s.curveId, curveId, "curveId");
        assertEq(s.makerPositionKey, desc.makerPositionKey, "makerPositionKey");
        assertEq(s.pairKey, _pairKey(desc.tokenA, desc.tokenB), "pairKey");
        assertEq(uint8((s.metaWord >> 178) & 0xFF), STATUS_UPDATED, "status");
        assertEq(uint8((s.metaWord >> 186) & 0xFF), PACKING_VERSION, "version");

        assertEq(uint128(s.priceWord), params.startPrice, "startPrice packed");
        assertEq(uint128(s.priceWord >> 128), params.endPrice, "endPrice packed");
        assertEq(uint128(s.volumeWord), desc.maxVolume, "maxVolume packed");
        assertEq(uint128(s.volumeWord >> 128), curve.remainingVolume, "remainingVolume packed");
        assertEq(s.commitment, curve.commitment, "commitment updated");
    }

    function test_curveSnapshotPackedFillPayload() public {
        (, uint256 curveId) = _createCurve(2e18, 2e18, uint64(block.timestamp), 1 days, 2e18, 0, 13);

        MamTypes.StoredCurve memory beforeCurve = harness.getStoredCurve(curveId);
        uint256 amountIn = 1e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, maxQuote);

        vm.prank(taker);
        tokenB.approve(address(harness), maxQuote);

        vm.recordLogs();
        vm.prank(taker);
        harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            1,
            uint64(block.timestamp + 1 days),
            taker,
            beforeCurve.generation,
            beforeCurve.commitment
        );

        Snapshot memory s = _snapshotFromLogs(vm.getRecordedLogs());
        MamTypes.StoredCurve memory afterCurve = harness.getStoredCurve(curveId);

        assertEq(uint8((s.metaWord >> 178) & 0xFF), STATUS_FILLED, "status");
        assertEq(uint128(s.volumeWord >> 128), afterCurve.remainingVolume, "remainingVolume packed");
        assertEq(s.commitment, afterCurve.commitment, "commitment persists");
        assertLt(afterCurve.remainingVolume, 2e18, "remaining should decrease");
    }

    function test_curveSnapshotPackedCancelPayload() public {
        (, uint256 curveId) = _createCurve(2e18, 1e18, uint64(block.timestamp), 1 days, 2e18, 100, 14);

        vm.recordLogs();
        vm.prank(maker);
        harness.cancelCurve(curveId);

        Snapshot memory s = _snapshotFromLogs(vm.getRecordedLogs());
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);

        assertEq(uint8((s.metaWord >> 178) & 0xFF), STATUS_CANCELLED, "status");
        assertEq(uint128(s.volumeWord >> 128), 0, "remainingVolume should be zero");
        assertEq(curve.remainingVolume, 0, "curve remainingVolume should be zero");
        assertEq(s.commitment, bytes32(0), "commitment should be zero");
    }

    function test_curveSnapshotPackedExpirePayload() public {
        (, uint256 curveId) = _createCurve(2e18, 1e18, uint64(block.timestamp), 1 days, 2e18, 100, 15);

        vm.warp(block.timestamp + 2 days);

        vm.recordLogs();
        harness.expireCurve(curveId);

        Snapshot memory s = _snapshotFromLogs(vm.getRecordedLogs());
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);

        assertEq(uint8((s.metaWord >> 178) & 0xFF), STATUS_EXPIRED, "status");
        assertEq(uint128(s.volumeWord >> 128), 0, "remainingVolume should be zero");
        assertEq(curve.remainingVolume, 0, "curve remainingVolume should be zero");
        assertEq(s.commitment, bytes32(0), "commitment should be zero");
    }

    function _createCurve(
        uint128 startPrice,
        uint128 endPrice,
        uint64 startTime,
        uint64 duration,
        uint128 maxVolume,
        uint16 feeRateBps,
        uint96 salt
    ) internal returns (MamTypes.CurveDescriptor memory desc, uint256 curveId) {
        (desc,) = _seedAndDescriptor(startPrice, endPrice, startTime, duration, maxVolume, feeRateBps, salt);

        vm.prank(maker);
        curveId = harness.createCurve(desc);
    }

    function _seedAndDescriptor(
        uint128 startPrice,
        uint128 endPrice,
        uint64 startTime,
        uint64 duration,
        uint128 maxVolume,
        uint16 feeRateBps,
        uint96 salt
    ) internal returns (MamTypes.CurveDescriptor memory desc, uint256 makerTokenId) {
        makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 5e18, 5e18);
        harness.seedPool(2, address(tokenB), positionKey, 5e18, 5e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: maxVolume,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: startTime,
            duration: duration,
            generation: 1,
            feeRateBps: feeRateBps,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: salt,
            profile: address(0),
            profileParams: bytes32(0)
        });
    }

    function _snapshotFromLogs(Vm.Log[] memory logs) internal pure returns (Snapshot memory snap) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == SNAPSHOT_SIG) {
                snap.curveId = uint256(logs[i].topics[1]);
                snap.makerPositionKey = logs[i].topics[2];
                snap.pairKey = logs[i].topics[3];
                (
                    snap.metaWord,
                    snap.priceWord,
                    snap.volumeWord,
                    snap.profile,
                    snap.profileParams,
                    snap.commitment
                ) = abi.decode(logs[i].data, (uint256, uint256, uint256, address, bytes32, bytes32));
                return snap;
            }
        }
        revert("snapshot not found");
    }

    function _pairKey(address tokenA_, address tokenB_) internal pure returns (bytes32) {
        (address token0, address token1) = tokenA_ < tokenB_ ? (tokenA_, tokenB_) : (tokenB_, tokenA_);
        return keccak256(abi.encodePacked(token0, token1));
    }

    function _packMeta(
        uint16 feeRateBps,
        uint32 generation,
        uint64 startTime,
        uint64 duration,
        bool baseIsA,
        bool priceIsQuotePerBase,
        uint8 status,
        uint8 version
    ) internal pure returns (uint256 metaWord) {
        metaWord = uint256(feeRateBps);
        metaWord |= uint256(generation) << 16;
        metaWord |= uint256(startTime) << 48;
        metaWord |= uint256(duration) << 112;
        if (baseIsA) metaWord |= uint256(1) << 176;
        if (priceIsQuotePerBase) metaWord |= uint256(1) << 177;
        metaWord |= uint256(status) << 178;
        metaWord |= uint256(version) << 186;
    }

    function _packPrice(uint128 startPrice, uint128 endPrice) internal pure returns (uint256 priceWord) {
        priceWord = uint256(startPrice);
        priceWord |= uint256(endPrice) << 128;
    }

    function _packVolume(uint128 maxVolume, uint128 remainingVolume) internal pure returns (uint256 volumeWord) {
        volumeWord = uint256(maxVolume);
        volumeWord |= uint256(remainingVolume) << 128;
    }

    function _assertMetaFields(
        uint256 metaWord,
        uint16 feeRateBps,
        uint32 generation,
        uint64 startTime,
        uint64 duration,
        bool baseIsA,
        bool priceIsQuotePerBase,
        uint8 status,
        uint8 version
    ) internal {
        assertEq(uint16(metaWord), feeRateBps, "feeRateBps bits");
        assertEq(uint32(metaWord >> 16), generation, "generation bits");
        assertEq(uint64(metaWord >> 48), startTime, "startTime bits");
        assertEq(uint64(metaWord >> 112), duration, "duration bits");
        assertEq(((metaWord >> 176) & 1) == 1, baseIsA, "baseIsA bit");
        assertEq(((metaWord >> 177) & 1) == 1, priceIsQuotePerBase, "priceIsQuotePerBase bit");
        assertEq(uint8((metaWord >> 178) & 0xFF), status, "status bits");
        assertEq(uint8((metaWord >> 186) & 0xFF), version, "version bits");
    }
}
