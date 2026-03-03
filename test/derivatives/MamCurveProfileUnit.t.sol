// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "src/EqualX/MamCurveExecutionFacet.sol";
import {MamCurveViewFacet} from "src/views/MamCurveViewFacet.sol";
import {ICurveProfile} from "src/interfaces/ICurveProfile.sol";
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
import "src/libraries/MamCurveErrors.sol";

contract UnitFixedPriceProfile is ICurveProfile {
    uint256 internal immutable fixedPrice;

    constructor(uint256 price_) {
        fixedPrice = price_;
    }

    function computePrice(uint256, uint256, uint256, uint256, uint256, bytes32)
        external
        view
        returns (uint256 price)
    {
        return fixedPrice;
    }
}

contract UnitRevertingProfile is ICurveProfile {
    error UnitRevertingProfile_Boom();

    function computePrice(uint256, uint256, uint256, uint256, uint256, bytes32)
        external
        pure
        returns (uint256)
    {
        revert UnitRevertingProfile_Boom();
    }
}

contract MamCurveProfileUnitHarness is
    MamCurveCreationFacet,
    MamCurveManagementFacet,
    MamCurveExecutionFacet,
    MamCurveViewFacet
{
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setOwner(address owner_) external {
        LibDiamond.diamondStorage().contractOwner = owner_;
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
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

    function getCurveProfileData(uint256 curveId) external view returns (LibDerivativeStorage.CurveProfileData memory) {
        return LibDerivativeStorage.derivativeStorage().curveProfileData[curveId];
    }

    function getStoredCurve(uint256 curveId) external view returns (MamTypes.StoredCurve memory) {
        return LibDerivativeStorage.derivativeStorage().curves[curveId];
    }
}

contract MamCurveProfileUnitTest is Test {
    event CurveProfileSet(uint16 indexed profileId, address impl, uint32 flags, bool approved);
    event CurveProfileTransition(uint256 indexed curveId, uint16 indexed oldProfileId, uint16 indexed newProfileId);

    uint16 internal constant LINEAR_ID = 1;
    uint16 internal constant PROFILE_A_ID = 2;
    uint16 internal constant PROFILE_B_ID = 3;
    uint16 internal constant REVERTING_PROFILE_ID = 4;

    MamCurveProfileUnitHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    UnitFixedPriceProfile internal profileA;
    UnitFixedPriceProfile internal profileB;
    UnitRevertingProfile internal revertingProfile;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    function setUp() public {
        harness = new MamCurveProfileUnitHarness();
        harness.setOwner(address(this));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        profileA = new UnitFixedPriceProfile(2e18);
        profileB = new UnitFixedPriceProfile(4e18);
        revertingProfile = new UnitRevertingProfile();

        harness.setCurveProfile(PROFILE_A_ID, address(profileA), 0, true);
        harness.setCurveProfile(PROFILE_B_ID, address(profileB), 0, true);
        harness.setCurveProfile(REVERTING_PROFILE_ID, address(revertingProfile), 0, true);

        harness.configurePositionNFT(address(nft));
        vm.warp(1 days);
    }

    function test_createCurveWithZeroProfileIdReverts() public {
        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(0, bytes32(0), 11);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidProfileId.selector, uint16(0)));
        harness.createCurve(desc);
    }

    function test_updateWithUpdateProfileFalseKeepsCurrentProfile() public {
        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(PROFILE_A_ID, bytes32("A"), 12);

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 2 days,
            updateProfile: false,
            profileId: PROFILE_B_ID,
            updateProfileParams: true,
            profileParams: bytes32("NEW_PARAMS")
        });

        vm.prank(maker);
        harness.updateCurve(curveId, params);

        LibDerivativeStorage.CurveProfileData memory stored = harness.getCurveProfileData(curveId);
        assertEq(stored.profileId, PROFILE_A_ID, "profileId should stay unchanged");
        assertEq(stored.profileParams, bytes32("NEW_PARAMS"), "profile params should update");
    }

    function test_updateWithUpdateProfileParamsFalseKeepsCurrentParams() public {
        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(PROFILE_A_ID, bytes32("ORIG"), 13);

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 2 days,
            updateProfile: true,
            profileId: PROFILE_B_ID,
            updateProfileParams: false,
            profileParams: bytes32("IGNORED")
        });

        vm.prank(maker);
        harness.updateCurve(curveId, params);

        LibDerivativeStorage.CurveProfileData memory stored = harness.getCurveProfileData(curveId);
        assertEq(stored.profileId, PROFILE_B_ID, "profileId should change");
        assertEq(stored.profileParams, bytes32("ORIG"), "params should stay unchanged");
    }

    function test_revokeProfileUsedByActiveCurveHasNoRetroactiveEffect() public {
        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(PROFILE_A_ID, bytes32("ACTIVE"), 14);

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        harness.setCurveProfile(PROFILE_A_ID, address(profileA), 0, false);
        assertFalse(harness.isCurveProfileApproved(PROFILE_A_ID), "profile should be revoked");

        MamTypes.CurveFillView memory fillView = harness.loadCurveForFill(curveId);
        assertEq(fillView.profileId, PROFILE_A_ID, "stored curve profileId should remain");

        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);
        tokenB.mint(taker, 2e18);
        vm.prank(taker);
        tokenB.approve(address(harness), 2e18);

        vm.prank(taker);
        uint256 out = harness.executeCurveSwap(
            curveId,
            2e18,
            2e18,
            1,
            uint64(block.timestamp + 1 days),
            taker,
            curve.generation,
            curve.commitment
        );
        assertEq(out, 1e18, "swap should still execute");
    }

    function test_profileStaticcallRevertPropagates() public {
        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(REVERTING_PROFILE_ID, bytes32(0), 15);

        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        vm.expectRevert(UnitRevertingProfile.UnitRevertingProfile_Boom.selector);
        harness.quoteCurveExactIn(curveId, 2e18);

        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);
        vm.prank(taker);
        vm.expectRevert(UnitRevertingProfile.UnitRevertingProfile_Boom.selector);
        harness.executeCurveSwap(
            curveId,
            2e18,
            2e18,
            1,
            uint64(block.timestamp + 1 days),
            taker,
            curve.generation,
            curve.commitment
        );
    }

    function test_batchCreateAndBatchUpdateWithProfileFields() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        _seedMakerPools(positionKey);

        MamTypes.CurveDescriptor[] memory descs = new MamTypes.CurveDescriptor[](2);
        descs[0] = _descriptor(positionKey, makerTokenId, PROFILE_A_ID, bytes32("P0"), 16);
        descs[1] = _descriptor(positionKey, makerTokenId, PROFILE_A_ID, bytes32("P1"), 17);

        vm.prank(maker);
        uint256 firstCurveId = harness.createCurvesBatch(descs);

        uint256 secondCurveId = firstCurveId + 1;
        assertEq(harness.getCurveProfileData(firstCurveId).profileParams, bytes32("P0"), "first params mismatch");
        assertEq(harness.getCurveProfileData(secondCurveId).profileParams, bytes32("P1"), "second params mismatch");

        uint256[] memory curveIds = new uint256[](2);
        curveIds[0] = firstCurveId;
        curveIds[1] = secondCurveId;

        MamTypes.CurveUpdateParams[] memory params = new MamTypes.CurveUpdateParams[](2);
        params[0] = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 2 days,
            updateProfile: true,
            profileId: PROFILE_B_ID,
            updateProfileParams: true,
            profileParams: bytes32("N0")
        });
        params[1] = MamTypes.CurveUpdateParams({
            startPrice: 4e18,
            endPrice: 3e18,
            startTime: uint64(block.timestamp + 2 hours),
            duration: 3 days,
            updateProfile: true,
            profileId: PROFILE_B_ID,
            updateProfileParams: true,
            profileParams: bytes32("N1")
        });

        vm.prank(maker);
        harness.updateCurvesBatch(curveIds, params);

        assertEq(harness.getCurveProfileData(firstCurveId).profileId, PROFILE_B_ID, "first profileId mismatch");
        assertEq(harness.getCurveProfileData(firstCurveId).profileParams, bytes32("N0"), "first params mismatch");
        assertEq(harness.getCurveProfileData(secondCurveId).profileId, PROFILE_B_ID, "second profileId mismatch");
        assertEq(harness.getCurveProfileData(secondCurveId).profileParams, bytes32("N1"), "second params mismatch");

        assertEq(harness.getStoredCurve(firstCurveId).generation, 2, "first generation mismatch");
        assertEq(harness.getStoredCurve(secondCurveId).generation, 2, "second generation mismatch");
    }

    function test_eventEmission_profileRegistryAndTransition() public {
        vm.expectEmit(true, false, false, true, address(harness));
        emit CurveProfileSet(PROFILE_A_ID, address(profileA), 7, true);
        harness.setCurveProfile(PROFILE_A_ID, address(profileA), 7, true);

        (MamTypes.CurveDescriptor memory desc,) = _seedAndDescriptor(PROFILE_A_ID, bytes32("X"), 18);
        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 2 days,
            updateProfile: true,
            profileId: PROFILE_B_ID,
            updateProfileParams: false,
            profileParams: bytes32(0)
        });

        vm.expectEmit(true, true, true, true, address(harness));
        emit CurveProfileTransition(curveId, PROFILE_A_ID, PROFILE_B_ID);
        vm.prank(maker);
        harness.updateCurve(curveId, params);
    }

    function _seedAndDescriptor(uint16 profileId, bytes32 profileParams, uint96 salt)
        internal
        returns (MamTypes.CurveDescriptor memory desc, uint256 makerTokenId)
    {
        makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        _seedMakerPools(positionKey);
        desc = _descriptor(positionKey, makerTokenId, profileId, profileParams, salt);
    }

    function _seedMakerPools(bytes32 positionKey) internal {
        harness.seedPool(1, address(tokenA), positionKey, 5e18, 5e18);
        harness.seedPool(2, address(tokenB), positionKey, 5e18, 5e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function _descriptor(
        bytes32 positionKey,
        uint256 makerPositionId,
        uint16 profileId,
        bytes32 profileParams,
        uint96 salt
    ) internal view returns (MamTypes.CurveDescriptor memory desc) {
        desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerPositionId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 2e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 0,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: salt,
            profileId: profileId,
            profileParams: profileParams
        });
    }
}
