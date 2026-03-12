// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveViewFacet} from "../../src/views/MamCurveViewFacet.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract MockMamViewTokenV1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MamCurveViewV1Harness is MamCurveCreationFacet, MamCurveViewFacet {
    function configureAccess(address owner_, address timelock_) external {
        LibDiamond.setContractOwner(owner_);
        LibAppStorage.s().timelock = timelock_;
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
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
            MockMamViewTokenV1(underlying).mint(address(this), tracked);
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
}

contract MamCurveViewFacetV1Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant MAKER = address(0x1111);
    address internal constant MAKER_2 = address(0x3333);

    MamCurveViewV1Harness internal harness;
    PositionNFT internal nft;
    MockMamViewTokenV1 internal tokenA;
    MockMamViewTokenV1 internal tokenB;

    function setUp() public {
        harness = new MamCurveViewV1Harness();
        harness.configureAccess(OWNER, TIMELOCK);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));

        tokenA = new MockMamViewTokenV1("TokenA", "A", 18);
        tokenB = new MockMamViewTokenV1("TokenB", "B", 18);

        vm.warp(1 days);
    }

    function test_getCurveStatus_quoteCurveExactIn_andBatchQuote() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 20e18, 20e18);
        MamTypes.CurveDescriptor memory desc =
            _descriptor(makerPositionId, makerKey, 1, uint64(block.timestamp + 5 minutes));
        desc.startPrice = 2e18;
        desc.endPrice = 2e18;

        vm.prank(MAKER);
        uint256 curveId = harness.createCurve(desc);

        vm.warp(block.timestamp + 10 minutes);

        (
            bool active,
            bool expired,
            uint128 remainingVolume,
            uint256 currentPrice,
            uint64 startTime,
            uint64 endTime,
            bool baseIsA,
            address statusTokenA,
            address statusTokenB,
            uint256 timeRemaining
        ) = harness.getCurveStatus(curveId);
        assertTrue(active);
        assertFalse(expired);
        assertEq(remainingVolume, 2e18);
        assertEq(currentPrice, 2e18);
        assertEq(startTime, desc.startTime);
        assertEq(endTime, desc.startTime + desc.duration);
        assertTrue(baseIsA);
        assertEq(statusTokenA, address(tokenA));
        assertEq(statusTokenB, address(tokenB));
        assertEq(timeRemaining, uint256(endTime) - block.timestamp);

        (uint256 amountOut, uint256 feeAmount, uint256 totalQuote, uint128 quotedRemaining, bool ok) =
            harness.quoteCurveExactIn(curveId, 2e18);
        assertTrue(ok);
        assertEq(amountOut, 1e18);
        assertEq(feeAmount, 2e16);
        assertEq(totalQuote, 202e16);
        assertEq(quotedRemaining, 2e18);

        uint256[] memory curveIds = new uint256[](1);
        curveIds[0] = curveId;
        uint256[] memory amountIns = new uint256[](1);
        amountIns[0] = 2e18;
        (uint256[] memory amountOuts, uint256[] memory feeAmounts, bool[] memory oks) =
            harness.quoteCurvesExactInBatch(curveIds, amountIns);
        assertEq(amountOuts.length, 1);
        assertEq(feeAmounts.length, 1);
        assertEq(oks.length, 1);
        assertEq(amountOuts[0], amountOut);
        assertEq(feeAmounts[0], feeAmount);
        assertTrue(oks[0]);

        vm.warp(uint256(endTime) + 1);
        uint128 ignoredRemaining;
        uint256 ignoredPrice;
        uint64 ignoredStartTime;
        bool ignoredBaseIsA;
        address ignoredTokenA;
        address ignoredTokenB;
        (
            active,
            expired,
            ignoredRemaining,
            ignoredPrice,
            ignoredStartTime,
            endTime,
            ignoredBaseIsA,
            ignoredTokenA,
            ignoredTokenB,
            timeRemaining
        ) = harness.getCurveStatus(curveId);
        ignoredRemaining;
        ignoredPrice;
        ignoredStartTime;
        ignoredBaseIsA;
        ignoredTokenA;
        ignoredTokenB;
        assertTrue(active);
        assertTrue(expired);
        assertEq(timeRemaining, 0);

        (amountOut, feeAmount, totalQuote, quotedRemaining, ok) = harness.quoteCurveExactIn(curveId, 2e18);
        assertFalse(ok);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);
        assertEq(totalQuote, 0);
        assertEq(quotedRemaining, 2e18);
    }

    function test_curvePagination_byPositionPairAndGlobal() public {
        (uint256 makerPositionId1, bytes32 makerKey1) = _seedMakerState(MAKER, 20e18, 20e18);
        (uint256 makerPositionId2, bytes32 makerKey2) = _seedMakerState(MAKER_2, 20e18, 20e18);

        vm.startPrank(MAKER);
        uint256 curve1 = harness.createCurve(_descriptor(makerPositionId1, makerKey1, 11, uint64(block.timestamp + 5 minutes)));
        uint256 curve2 = harness.createCurve(_descriptor(makerPositionId1, makerKey1, 12, uint64(block.timestamp + 6 minutes)));
        vm.stopPrank();

        vm.prank(MAKER_2);
        uint256 curve3 = harness.createCurve(_descriptor(makerPositionId2, makerKey2, 13, uint64(block.timestamp + 7 minutes)));

        (uint256[] memory ids, uint256 total) = harness.getCurvesByPosition(makerKey1, 0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], curve1);
        assertEq(ids[1], curve2);

        (ids, total) = harness.getCurvesByPositionId(makerPositionId1, 1, 10);
        assertEq(total, 2);
        assertEq(ids.length, 1);
        assertEq(ids[0], curve2);

        (ids, total) = harness.getActiveCurves(0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], curve1);
        assertEq(ids[1], curve2);
        assertEq(ids[2], curve3);

        (ids, total) = harness.getActiveCurves(1, 1);
        assertEq(total, 3);
        assertEq(ids.length, 1);
        assertEq(ids[0], curve2);

        (ids, total) = harness.getCurvesByPair(address(tokenA), address(tokenB), 0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], curve1);
        assertEq(ids[1], curve2);
        assertEq(ids[2], curve3);

        (ids, total) = harness.getCurvesByPair(address(tokenB), address(tokenA), 0, 10);
        assertEq(total, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], curve1);
        assertEq(ids[1], curve2);
        assertEq(ids[2], curve3);
    }

    function test_quoteCurvesExactInBatch_revertsOnLengthMismatch() public {
        uint256[] memory curveIds = new uint256[](2);
        curveIds[0] = 1;
        curveIds[1] = 2;
        uint256[] memory amountIns = new uint256[](1);
        amountIns[0] = 1e18;

        vm.expectRevert(bytes("MamCurveView: length mismatch"));
        harness.quoteCurvesExactInBatch(curveIds, amountIns);
    }

    function _seedMakerState(address owner, uint256 reserveA, uint256 reserveB)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        positionId = nft.mint(owner, 1);
        positionKey = nft.getPositionKey(positionId);
        harness.seedPool(1, address(tokenA), positionKey, reserveA, reserveA);
        harness.seedPool(2, address(tokenB), positionKey, reserveB, reserveB);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function _descriptor(uint256 positionId, bytes32 positionKey, uint96 salt, uint64 startTime)
        internal
        view
        returns (MamTypes.CurveDescriptor memory)
    {
        return MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: positionId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: startTime,
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: salt,
            profileId: 1,
            profileParams: bytes32(0)
        });
    }
}
