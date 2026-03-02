// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "src/EqualX/MamCurveExecutionFacet.sol";
import {MamCurveViewFacet} from "src/views/MamCurveViewFacet.sol";
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

contract MamCurveProfileLifecycleHarness is
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
}

contract MamCurveProfileLifecyclePropertyTest is Test {
    MamCurveProfileLifecycleHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);

    function setUp() public {
        harness = new MamCurveProfileLifecycleHarness();
        harness.setOwner(address(this));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        harness.configurePositionNFT(address(nft));
        vm.warp(1 days);
    }

    // Property 6: Unapproved profile reverts curve creation
    function testFuzz_unapprovedProfileRevertsCreate(address profile, bytes32 profileParams) public {
        vm.assume(profile != address(0));

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        _seedMakerPools(positionKey);

        MamTypes.CurveDescriptor memory desc = _descriptor(positionKey, makerTokenId, profile, profileParams, 1);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_ProfileNotApproved.selector, profile));
        harness.createCurve(desc);
    }

    // Property 8: Profile data round-trips through create and read
    function testFuzz_profileDataRoundTripsThroughCreateAndRead(address profile, bytes32 profileParams, uint96 salt)
        public
    {
        vm.assume(profile != address(0));

        harness.approveCurveProfile(profile);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        _seedMakerPools(positionKey);

        MamTypes.CurveDescriptor memory desc = _descriptor(positionKey, makerTokenId, profile, profileParams, salt);
        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        LibDerivativeStorage.CurveProfileData memory stored = harness.getCurveProfileData(curveId);
        assertEq(stored.profile, profile, "stored profile mismatch");
        assertEq(stored.profileParams, profileParams, "stored profileParams mismatch");

        MamTypes.CurveFillView memory fillView = harness.loadCurveForFill(curveId);
        assertEq(fillView.profile, profile, "fill view profile mismatch");
        assertEq(fillView.profileParams, profileParams, "fill view profileParams mismatch");

        (, , , LibDerivativeStorage.CurveProfileData memory getCurveProfileData,,) = harness.getCurve(curveId);
        assertEq(getCurveProfileData.profile, profile, "getCurve profile mismatch");
        assertEq(getCurveProfileData.profileParams, profileParams, "getCurve profileParams mismatch");
    }

    // Property 7: Unapproved profile reverts update when updateProfile=true
    function testFuzz_unapprovedProfileRevertsUpdateWhenUpdateProfileTrue(
        address approvedProfile,
        address unapprovedProfile,
        bytes32 approvedParams,
        uint96 salt
    ) public {
        vm.assume(approvedProfile != address(0));
        vm.assume(unapprovedProfile != address(0));
        vm.assume(approvedProfile != unapprovedProfile);

        harness.approveCurveProfile(approvedProfile);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        _seedMakerPools(positionKey);

        MamTypes.CurveDescriptor memory desc =
            _descriptor(positionKey, makerTokenId, approvedProfile, approvedParams, salt);
        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 2 days,
            updateProfile: true,
            profile: unapprovedProfile,
            updateProfileParams: false,
            profileParams: bytes32(0)
        });

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_ProfileNotApproved.selector, unapprovedProfile));
        harness.updateCurve(curveId, params);
    }

    // Property 10: Update increments generation and changes commitment
    function testFuzz_updateIncrementsGenerationAndChangesCommitment(
        address oldProfile,
        address nextProfile,
        bytes32 oldProfileParams,
        bytes32 nextProfileParams,
        uint128 startPrice,
        uint128 endPrice,
        uint96 salt
    ) public {
        vm.assume(oldProfile != address(0));
        vm.assume(nextProfile != address(0));
        vm.assume(oldProfile != nextProfile);
        vm.assume(startPrice > 0);
        vm.assume(endPrice > 0);

        harness.approveCurveProfile(oldProfile);
        harness.approveCurveProfile(nextProfile);

        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);
        _seedMakerPools(positionKey);

        MamTypes.CurveDescriptor memory desc =
            _descriptor(positionKey, makerTokenId, oldProfile, oldProfileParams, salt);
        vm.prank(maker);
        uint256 curveId = harness.createCurve(desc);

        (MamTypes.StoredCurve memory beforeCurve,,,,,) = harness.getCurve(curveId);
        LibDerivativeStorage.CurveProfileData memory beforeProfile = harness.getCurveProfileData(curveId);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: uint64(block.timestamp + 2 hours),
            duration: 3 days,
            updateProfile: true,
            profile: nextProfile,
            updateProfileParams: true,
            profileParams: nextProfileParams
        });

        vm.prank(maker);
        harness.updateCurve(curveId, params);

        (MamTypes.StoredCurve memory afterCurve,,,,,) = harness.getCurve(curveId);
        LibDerivativeStorage.CurveProfileData memory afterProfile = harness.getCurveProfileData(curveId);

        assertEq(afterCurve.generation, beforeCurve.generation + 1, "generation should increment");
        assertTrue(afterCurve.commitment != beforeCurve.commitment, "commitment should change");
        assertEq(afterProfile.profile, nextProfile, "profile should update");
        assertEq(afterProfile.profileParams, nextProfileParams, "profile params should update");
        assertEq(beforeProfile.profile, oldProfile, "precondition old profile");
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
        address profile,
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
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: salt,
            profile: profile,
            profileParams: profileParams
        });
    }
}
