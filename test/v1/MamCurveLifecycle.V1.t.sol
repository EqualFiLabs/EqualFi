// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {NotNFTOwner, PoolMembershipRequired} from "../../src/libraries/Errors.sol";
import "../../src/libraries/MamCurveErrors.sol";

contract MockMamTokenV1 is ERC20 {
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

contract MamCurveV1Harness is MamCurveCreationFacet, MamCurveManagementFacet, MamCurveExecutionFacet, MamCurveViewFacet {
    function configureAccess(address owner_, address timelock_) external {
        LibDiamond.setContractOwner(owner_);
        LibAppStorage.s().timelock = timelock_;
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setMamMakerShareBps(uint16 bps) external {
        LibDerivativeStorage.derivativeStorage().config.mamMakerShareBps = bps;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
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
            MockMamTokenV1(underlying).mint(address(this), tracked);
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

    function directLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function storedCurve(uint256 curveId) external view returns (MamTypes.StoredCurve memory) {
        return LibDerivativeStorage.derivativeStorage().curves[curveId];
    }

    function curveProfile(uint256 curveId) external view returns (uint16 profileId, bytes32 profileParams) {
        LibDerivativeStorage.CurveProfileData storage profileData = LibDerivativeStorage.derivativeStorage().curveProfileData[curveId];
        return (profileData.profileId, profileData.profileParams);
    }
}

contract MamCurveLifecycleV1Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant MAKER = address(0x1111);
    address internal constant TAKER = address(0x2222);

    MamCurveV1Harness internal harness;
    PositionNFT internal nft;
    MockMamTokenV1 internal tokenA;
    MockMamTokenV1 internal tokenB;

    function setUp() public {
        harness = new MamCurveV1Harness();
        harness.configureAccess(OWNER, TIMELOCK);
        harness.setMamMakerShareBps(7000);
        harness.setTreasury(address(0xC0FFEE));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));

        tokenA = new MockMamTokenV1("TokenA", "A", 18);
        tokenB = new MockMamTokenV1("TokenB", "B", 18);

        vm.warp(1 days);
    }

    function test_setMamPaused_andCurveProfile_accessControls() public {
        vm.prank(TAKER);
        vm.expectRevert("LibAccess: not owner or timelock");
        harness.setMamPaused(true);

        vm.prank(OWNER);
        harness.setMamPaused(true);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_Paused.selector));
        harness.createCurve(_dummyDescriptor());

        vm.prank(TAKER);
        vm.expectRevert("LibAccess: not owner or timelock");
        harness.setCurveProfile(2, address(0x1234), 0, true);

        vm.prank(OWNER);
        harness.setCurveProfile(2, address(0x1234), 77, true);
        (address impl, uint32 flags, bool approved) = harness.getCurveProfile(2);
        assertEq(impl, address(0x1234));
        assertEq(flags, 77);
        assertTrue(approved);
        assertTrue(harness.isCurveProfileApproved(2));
    }

    function test_createUpdateAndExecute_generationAndCommitmentGuards() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);

        vm.prank(MAKER);
        uint256 curveId = harness.createCurve(_descriptor(makerPositionId, makerKey, 1, uint64(block.timestamp + 5 minutes)));

        MamTypes.StoredCurve memory created = harness.storedCurve(curveId);
        bytes32 oldCommitment = created.commitment;
        uint32 oldGeneration = created.generation;
        assertEq(harness.directLocked(makerKey, 1), 2e18);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 15 minutes),
            duration: 1 days,
            updateProfile: false,
            profileId: 1,
            updateProfileParams: false,
            profileParams: bytes32(0)
        });
        vm.prank(MAKER);
        harness.updateCurve(curveId, params);

        MamTypes.StoredCurve memory updated = harness.storedCurve(curveId);
        assertEq(updated.generation, oldGeneration + 1);
        assertTrue(updated.commitment != oldCommitment);

        vm.warp(block.timestamp + 20 minutes);

        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(TAKER, maxQuote * 2);
        vm.prank(TAKER);
        tokenB.approve(address(harness), maxQuote * 2);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_GenerationMismatch.selector, oldGeneration, updated.generation));
        harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            0,
            uint64(block.timestamp + 1 days),
            TAKER,
            oldGeneration,
            oldCommitment
        );

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_CommitmentMismatch.selector, oldCommitment, updated.commitment));
        harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            0,
            uint64(block.timestamp + 1 days),
            TAKER,
            updated.generation,
            oldCommitment
        );

        vm.prank(TAKER);
        uint256 amountOut = harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            0,
            uint64(block.timestamp + 1 days),
            TAKER,
            updated.generation,
            updated.commitment
        );
        assertGt(amountOut, 0);
        assertEq(tokenA.balanceOf(TAKER), amountOut);

        MamTypes.StoredCurve memory afterFill = harness.storedCurve(curveId);
        assertLt(afterFill.remainingVolume, 2e18);
    }

    function test_batchLifecycle_cancelAndExpire_cleanupIndexes() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 12e18, 12e18);

        MamTypes.CurveDescriptor[] memory descs = new MamTypes.CurveDescriptor[](2);
        descs[0] = _descriptor(makerPositionId, makerKey, 11, uint64(block.timestamp + 5 minutes));
        descs[1] = _descriptor(makerPositionId, makerKey, 12, uint64(block.timestamp + 6 minutes));

        vm.prank(MAKER);
        uint256 firstId = harness.createCurvesBatch(descs);

        (uint256[] memory ids, uint256 total) = harness.getActiveCurves(0, 10);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], firstId);
        assertEq(ids[1], firstId + 1);

        MamTypes.CurveUpdateParams[] memory params = new MamTypes.CurveUpdateParams[](2);
        params[0] = MamTypes.CurveUpdateParams({
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp + 20 minutes),
            duration: 1 days,
            updateProfile: false,
            profileId: 1,
            updateProfileParams: false,
            profileParams: bytes32(0)
        });
        params[1] = MamTypes.CurveUpdateParams({
            startPrice: 25e17,
            endPrice: 12e17,
            startTime: uint64(block.timestamp + 25 minutes),
            duration: 1 days,
            updateProfile: false,
            profileId: 1,
            updateProfileParams: false,
            profileParams: bytes32(0)
        });

        uint256[] memory batchIds = new uint256[](2);
        batchIds[0] = firstId;
        batchIds[1] = firstId + 1;

        vm.prank(MAKER);
        harness.updateCurvesBatch(batchIds, params);
        assertEq(harness.storedCurve(firstId).generation, 2);
        assertEq(harness.storedCurve(firstId + 1).generation, 2);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, TAKER, makerPositionId));
        harness.cancelCurve(firstId);

        assertEq(harness.directLocked(makerKey, 1), 4e18);
        vm.prank(MAKER);
        harness.cancelCurvesBatch(batchIds);
        assertEq(harness.directLocked(makerKey, 1), 0);
        assertFalse(harness.storedCurve(firstId).active);
        assertFalse(harness.storedCurve(firstId + 1).active);

        vm.prank(MAKER);
        uint256 expiringId = harness.createCurve(_descriptor(makerPositionId, makerKey, 99, uint64(block.timestamp)));
        assertEq(harness.directLocked(makerKey, 1), 2e18);

        vm.warp(block.timestamp + 2 days);
        harness.expireCurve(expiringId);
        assertEq(harness.directLocked(makerKey, 1), 0);

        (ids, total) = harness.getActiveCurves(0, 10);
        assertEq(total, 0);
        assertEq(ids.length, 0);
    }

    function test_expireCurvesBatch_expiresAllAndUnlocksCollateral() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 12e18, 12e18);

        vm.prank(MAKER);
        uint256 firstId = harness.createCurve(_descriptor(makerPositionId, makerKey, 500, uint64(block.timestamp)));
        vm.prank(MAKER);
        uint256 secondId = harness.createCurve(_descriptor(makerPositionId, makerKey, 501, uint64(block.timestamp)));

        assertEq(harness.directLocked(makerKey, 1), 4e18);

        uint256[] memory batchIds = new uint256[](2);
        batchIds[0] = firstId;
        batchIds[1] = secondId;

        vm.warp(block.timestamp + 2 days);
        harness.expireCurvesBatch(batchIds);

        assertEq(harness.directLocked(makerKey, 1), 0);
        assertFalse(harness.storedCurve(firstId).active);
        assertFalse(harness.storedCurve(secondId).active);

        (uint256[] memory ids, uint256 total) = harness.getActiveCurves(0, 10);
        assertEq(total, 0);
        assertEq(ids.length, 0);
    }

    function test_createCurve_descriptorValidation_zeroAndTimeWindows() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);
        MamTypes.CurveDescriptor memory desc = _descriptor(makerPositionId, makerKey, 101, uint64(block.timestamp + 5 minutes));

        desc.maxVolume = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidAmount.selector, 0));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 102, uint64(block.timestamp + 5 minutes));
        desc.startPrice = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 103, uint64(block.timestamp + 5 minutes));
        desc.endPrice = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 104, uint64(block.timestamp + 5 minutes));
        desc.duration = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidTime.selector, desc.startTime, uint64(0)));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 105, uint64(block.timestamp - 31 minutes));
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidTime.selector, desc.startTime, desc.duration));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 106, type(uint64).max);
        desc.duration = 2;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidTime.selector, desc.startTime, desc.duration));
        harness.createCurve(desc);
    }

    function test_createCurve_descriptorValidation_poolTokenMembershipAndFlags() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);
        MamTypes.CurveDescriptor memory desc = _descriptor(makerPositionId, makerKey, 201, uint64(block.timestamp + 5 minutes));

        desc.poolIdB = 1;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidPool.selector, 1));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 202, uint64(block.timestamp + 5 minutes));
        desc.tokenB = desc.tokenA;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 203, uint64(block.timestamp + 5 minutes));
        desc.tokenA = address(tokenB);
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 204, uint64(block.timestamp + 5 minutes));
        desc.priceIsQuotePerBase = false;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 205, uint64(block.timestamp + 5 minutes));
        desc.feeAsset = MamTypes.FeeAsset.TokenOut;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 206, uint64(block.timestamp + 5 minutes));
        desc.generation = 2;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.createCurve(desc);

        desc = _descriptor(makerPositionId, makerKey, 207, uint64(block.timestamp + 5 minutes));
        desc.profileId = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidProfileId.selector, uint16(0)));
        harness.createCurve(desc);

        uint256 missingBPositionId = nft.mint(MAKER, 1);
        bytes32 missingBKey = nft.getPositionKey(missingBPositionId);
        harness.seedPool(1, address(tokenA), missingBKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), missingBKey, 10e18, 10e18);
        harness.joinPool(missingBKey, 1);
        desc = _descriptor(missingBPositionId, missingBKey, 208, uint64(block.timestamp + 5 minutes));
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, missingBKey, 2));
        harness.createCurve(desc);

        uint256 missingAPositionId = nft.mint(MAKER, 1);
        bytes32 missingAKey = nft.getPositionKey(missingAPositionId);
        harness.seedPool(1, address(tokenA), missingAKey, 10e18, 10e18);
        harness.seedPool(2, address(tokenB), missingAKey, 10e18, 10e18);
        harness.joinPool(missingAKey, 2);
        desc = _descriptor(missingAPositionId, missingAKey, 209, uint64(block.timestamp + 5 minutes));
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, missingAKey, 1));
        harness.createCurve(desc);
    }

    function test_executeCurveSwap_guardReverts_deadlineRecipientSlippage() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);
        MamTypes.CurveDescriptor memory desc = _descriptor(makerPositionId, makerKey, 301, uint64(block.timestamp + 5 minutes));
        desc.endPrice = desc.startPrice;

        vm.prank(MAKER);
        uint256 curveId = harness.createCurve(desc);

        vm.warp(block.timestamp + 10 minutes);
        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        (uint256 quotedOut,,, uint128 remaining, bool ok) = harness.quoteCurveExactIn(curveId, amountIn);
        assertTrue(ok);
        assertEq(remaining, 2e18);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_Expired.selector, curveId));
        harness.executeCurveSwap(curveId, amountIn, maxQuote, 0, uint64(block.timestamp - 1), TAKER);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_InvalidDescriptor.selector));
        harness.executeCurveSwap(curveId, amountIn, maxQuote, 0, uint64(block.timestamp + 1 hours), address(0));

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_Slippage.selector, quotedOut + 1, quotedOut));
        harness.executeCurveSwap(curveId, amountIn, maxQuote, quotedOut + 1, uint64(block.timestamp + 1 hours), TAKER);
    }

    function test_executeCurveSwap_guardReverts_inactiveAndExpired() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);

        vm.prank(MAKER);
        uint256 inactiveCurveId = harness.createCurve(_descriptor(makerPositionId, makerKey, 401, uint64(block.timestamp + 5 minutes)));
        vm.prank(MAKER);
        harness.cancelCurve(inactiveCurveId);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_NotActive.selector, inactiveCurveId));
        harness.executeCurveSwap(inactiveCurveId, 1e18, 2e18, 0, uint64(block.timestamp + 1 hours), TAKER);

        MamTypes.CurveDescriptor memory expiringDesc =
            _descriptor(makerPositionId, makerKey, 402, uint64(block.timestamp + 1 minutes));
        expiringDesc.duration = 1 hours;
        vm.prank(MAKER);
        uint256 expiredCurveId = harness.createCurve(expiringDesc);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_Expired.selector, expiredCurveId));
        harness.executeCurveSwap(expiredCurveId, 1e18, 2e18, 0, uint64(block.timestamp + 1 hours), TAKER);
    }

    function test_updateCurve_profileTransitionApprovedAndUnapproved() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);

        vm.prank(MAKER);
        uint256 curveId = harness.createCurve(_descriptor(makerPositionId, makerKey, 501, uint64(block.timestamp + 5 minutes)));
        MamTypes.StoredCurve memory beforeCurve = harness.storedCurve(curveId);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 15 minutes),
            duration: 1 days,
            updateProfile: true,
            profileId: 2,
            updateProfileParams: false,
            profileParams: bytes32(0)
        });

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_ProfileNotApproved.selector, uint16(2)));
        harness.updateCurve(curveId, params);

        vm.prank(OWNER);
        harness.setCurveProfile(2, address(0x1234), 0, true);

        vm.prank(MAKER);
        harness.updateCurve(curveId, params);

        MamTypes.StoredCurve memory afterCurve = harness.storedCurve(curveId);
        (uint16 profileId,) = harness.curveProfile(curveId);
        assertEq(profileId, 2);
        assertEq(afterCurve.generation, beforeCurve.generation + 1);
        assertTrue(afterCurve.commitment != beforeCurve.commitment);
    }

    function test_updateCurve_updateProfileParamsMutatesCommitmentAndGeneration() public {
        (uint256 makerPositionId, bytes32 makerKey) = _seedMakerState(MAKER, 10e18, 10e18);

        vm.prank(MAKER);
        uint256 curveId = harness.createCurve(_descriptor(makerPositionId, makerKey, 601, uint64(block.timestamp + 5 minutes)));
        MamTypes.StoredCurve memory beforeCurve = harness.storedCurve(curveId);
        (uint16 oldProfileId, bytes32 oldProfileParams) = harness.curveProfile(curveId);

        MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
            startPrice: 22e17,
            endPrice: 11e17,
            startTime: uint64(block.timestamp + 20 minutes),
            duration: 2 days,
            updateProfile: false,
            profileId: 1,
            updateProfileParams: true,
            profileParams: bytes32(uint256(0xBEEF))
        });

        vm.prank(MAKER);
        harness.updateCurve(curveId, params);

        MamTypes.StoredCurve memory afterCurve = harness.storedCurve(curveId);
        (uint16 newProfileId, bytes32 newProfileParams) = harness.curveProfile(curveId);
        assertEq(newProfileId, oldProfileId);
        assertTrue(newProfileParams != oldProfileParams);
        assertEq(newProfileParams, params.profileParams);
        assertEq(afterCurve.generation, beforeCurve.generation + 1);
        assertTrue(afterCurve.commitment != beforeCurve.commitment);
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

    function _dummyDescriptor() internal view returns (MamTypes.CurveDescriptor memory desc) {
        desc.makerPositionKey = bytes32(uint256(1));
        desc.makerPositionId = 1;
        desc.poolIdA = 1;
        desc.poolIdB = 2;
        desc.tokenA = address(0x1);
        desc.tokenB = address(0x2);
        desc.side = false;
        desc.priceIsQuotePerBase = true;
        desc.maxVolume = 1;
        desc.startPrice = 1;
        desc.endPrice = 1;
        desc.startTime = uint64(block.timestamp);
        desc.duration = 1;
        desc.generation = 1;
        desc.feeRateBps = 0;
        desc.feeAsset = MamTypes.FeeAsset.TokenIn;
        desc.salt = 1;
        desc.profileId = 1;
        desc.profileParams = bytes32(0);
    }
}
