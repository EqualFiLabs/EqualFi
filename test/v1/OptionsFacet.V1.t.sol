// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    OptionsFacet,
    Options_ExerciseWindowClosed,
    Options_InsufficientBalance,
    Options_InvalidContractSize,
    Options_InvalidExpiry,
    Options_InvalidPool,
    Options_InvalidPrice,
    Options_InvalidRecipient,
    Options_InvalidSeries,
    Options_InvalidAmount,
    Options_NotTokenHolder,
    Options_NotReclaimed,
    Options_Paused,
    Options_Reclaimed,
    Options_TokenNotSet
} from "../../src/derivatives/OptionsFacet.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";
import {PoolMembershipRequired} from "../../src/libraries/Errors.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

contract MockTokenV1 is ERC20 {
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

contract OptionsV1Harness is OptionsFacet {
    function configureAccess(address owner_, address timelock_) external {
        LibDiamond.setContractOwner(owner_);
        LibAppStorage.s().timelock = timelock_;
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setEuropeanTolerance(uint64 tolerance) external {
        LibDerivativeStorage.derivativeStorage().config.europeanToleranceSeconds = tolerance;
    }

    function derivativeOptionToken() external view returns (address) {
        return LibDerivativeStorage.derivativeStorage().optionToken;
    }

    function optionsPausedState() external view returns (bool) {
        return LibDerivativeStorage.derivativeStorage().optionsPaused;
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
            MockTokenV1(underlying).mint(address(this), tracked);
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

    function lockedCollateral(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

contract OptionsFacetV1Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant MAKER = address(0x1111);
    address internal constant HOLDER = address(0x2222);
    address internal constant OPERATOR = address(0x3333);
    uint256 internal constant STRIKE_PRICE = 2e18;

    OptionsV1Harness internal harness;
    PositionNFT internal nft;
    OptionToken internal optionToken;
    MockTokenV1 internal underlying;
    MockTokenV1 internal strike;

    event SeriesCreated(
        uint256 indexed seriesId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        uint256 underlyingPoolId,
        uint256 strikePoolId,
        address underlyingAsset,
        address strikeAsset,
        uint256 strikePrice,
        uint64 expiry,
        uint256 totalSize,
        uint256 collateralLocked,
        bool isCall,
        bool isAmerican
    );

    event Exercised(
        uint256 indexed seriesId,
        address indexed holder,
        address indexed recipient,
        uint256 amount,
        uint256 strikeAmount,
        uint256 paymentReceived
    );

    event Reclaimed(
        uint256 indexed seriesId, bytes32 indexed makerPositionKey, uint256 remainingSize, uint256 collateralUnlocked
    );

    function setUp() public {
        harness = new OptionsV1Harness();
        harness.configureAccess(OWNER, TIMELOCK);

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.configurePositionNFT(address(nft));

        underlying = new MockTokenV1("Underlying", "UND", 18);
        strike = new MockTokenV1("Strike", "STK", 6);

        optionToken = new OptionToken("", address(this), address(harness));
    }

    function test_setOptionToken_andPause_accessControl() public {
        vm.prank(HOLDER);
        vm.expectRevert("LibAccess: not owner or timelock");
        harness.setOptionToken(address(optionToken));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Options_TokenNotSet.selector));
        harness.setOptionToken(address(0));

        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));
        assertEq(harness.derivativeOptionToken(), address(optionToken));

        vm.prank(HOLDER);
        vm.expectRevert("LibAccess: not owner or timelock");
        harness.setOptionsPaused(true);

        vm.prank(TIMELOCK);
        harness.setOptionsPaused(true);
        assertTrue(harness.optionsPausedState());
    }

    function test_createOptionSeries_revertsWhenPaused() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));
        vm.prank(OWNER);
        harness.setOptionsPaused(true);

        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
            positionId: 1,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: STRIKE_PRICE,
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

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_Paused.selector));
        harness.createOptionSeries(params);
    }

    function test_createExerciseAndReclaim_callSeriesFlow() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        (uint256 positionId, bytes32 positionKey, uint256 notional,) = _seedMakerState(1e18);
        uint256 makerUnderlyingBefore = harness.principalOf(1, positionKey);
        uint256 makerStrikeBefore = harness.principalOf(2, positionKey);

        vm.expectEmit(true, true, true, true);
        emit SeriesCreated(
            1,
            positionKey,
            positionId,
            1,
            2,
            address(underlying),
            address(strike),
            STRIKE_PRICE,
            uint64(block.timestamp + 1 days),
            notional,
            notional,
            true,
            true
        );
        vm.prank(MAKER);
        uint256 seriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: positionId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: STRIKE_PRICE,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: notional,
                contractSize: 1,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        assertEq(optionToken.balanceOf(MAKER, seriesId), notional);
        assertEq(harness.lockedCollateral(positionKey, 1), notional);

        uint256 exercised = 4e17;
        vm.prank(MAKER);
        optionToken.safeTransferFrom(MAKER, HOLDER, seriesId, exercised, "");

        uint256 payment = harness.previewExercisePayment(seriesId, exercised);
        assertEq(payment, _strikeAmount(exercised));
        strike.mint(HOLDER, payment);
        vm.prank(HOLDER);
        strike.approve(address(harness), payment);

        vm.expectEmit(true, true, true, true);
        emit Exercised(seriesId, HOLDER, HOLDER, exercised, payment, payment);
        vm.prank(HOLDER);
        harness.exerciseOptions(seriesId, exercised, HOLDER, payment, 0);

        DerivativeTypes.OptionSeries memory mid = harness.getOptionSeries(seriesId);
        assertEq(mid.remaining, notional - exercised);
        assertEq(harness.lockedCollateral(positionKey, 1), notional - exercised);
        assertEq(underlying.balanceOf(HOLDER), exercised);
        assertEq(harness.principalOf(1, positionKey), makerUnderlyingBefore - exercised);
        assertEq(harness.principalOf(2, positionKey), makerStrikeBefore + payment);

        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(Options_NotReclaimed.selector, seriesId));
        harness.burnReclaimedOptionsClaims(HOLDER, seriesId, 1);

        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, false, true);
        emit Reclaimed(seriesId, positionKey, notional - exercised, notional - exercised);
        vm.prank(MAKER);
        harness.reclaimOptions(seriesId);

        DerivativeTypes.OptionSeries memory done = harness.getOptionSeries(seriesId);
        assertTrue(done.reclaimed);
        assertEq(done.remaining, 0);
        assertEq(harness.lockedCollateral(positionKey, 1), 0);

        uint256 holderClaims = optionToken.balanceOf(HOLDER, seriesId);
        assertEq(holderClaims, 0);
        uint256 makerClaims = optionToken.balanceOf(MAKER, seriesId);
        assertEq(makerClaims, notional - exercised);
        vm.prank(address(0xCAFE));
        harness.burnReclaimedOptionsClaims(MAKER, seriesId, makerClaims / 2);
        assertEq(optionToken.balanceOf(MAKER, seriesId), makerClaims / 2);
    }

    function test_europeanWindow_enforced() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));
        harness.setEuropeanTolerance(100);

        (uint256 positionId,, uint256 notional,) = _seedMakerState(1e18);
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.prank(MAKER);
        uint256 seriesId = harness.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: positionId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: STRIKE_PRICE,
                expiry: expiry,
                totalSize: notional,
                contractSize: 1,
                isCall: true,
                isAmerican: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(MAKER);
        optionToken.safeTransferFrom(MAKER, HOLDER, seriesId, notional, "");

        uint256 payment = harness.previewExercisePayment(seriesId, notional);
        strike.mint(HOLDER, payment);
        vm.prank(HOLDER);
        strike.approve(address(harness), payment);

        vm.warp(expiry - 101);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(Options_ExerciseWindowClosed.selector, seriesId));
        harness.exerciseOptions(seriesId, notional, HOLDER, payment, 0);

        vm.warp(expiry);
        vm.prank(HOLDER);
        harness.exerciseOptions(seriesId, notional, HOLDER, payment, 0);
    }

    function test_createOptionSeries_basicValidation() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
            positionId: 1,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 0,
            contractSize: 1,
            isCall: true,
            isAmerican: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidAmount.selector, 0));
        harness.createOptionSeries(params);
    }

    function test_createExerciseAndReclaim_putSeriesFlow_tracksCollateralAndPrincipal() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        (uint256 positionId, bytes32 positionKey, uint256 notional, uint256 requiredStrike) = _seedMakerState(1e18);
        uint256 makerUnderlyingBefore = harness.principalOf(1, positionKey);
        uint256 makerStrikeBefore = harness.principalOf(2, positionKey);

        DerivativeTypes.CreateOptionSeriesParams memory params = _defaultSeriesParams(positionId, notional, false);
        vm.expectEmit(true, true, true, true);
        emit SeriesCreated(
            1,
            positionKey,
            positionId,
            1,
            2,
            address(underlying),
            address(strike),
            STRIKE_PRICE,
            uint64(block.timestamp + 1 days),
            notional,
            requiredStrike,
            false,
            true
        );
        vm.prank(MAKER);
        uint256 seriesId = harness.createOptionSeries(params);

        DerivativeTypes.OptionSeries memory created = harness.getOptionSeries(seriesId);
        assertEq(created.collateralLocked, requiredStrike);
        assertEq(harness.lockedCollateral(positionKey, 2), requiredStrike);

        uint256 exercised = 4e17;
        vm.prank(MAKER);
        optionToken.safeTransferFrom(MAKER, HOLDER, seriesId, exercised, "");

        uint256 payment = harness.previewExercisePayment(seriesId, exercised);
        assertEq(payment, exercised);
        underlying.mint(HOLDER, payment);
        vm.prank(HOLDER);
        underlying.approve(address(harness), payment);

        uint256 strikeOut = _strikeAmount(exercised);
        vm.expectEmit(true, true, true, true);
        emit Exercised(seriesId, HOLDER, HOLDER, exercised, strikeOut, payment);
        vm.prank(HOLDER);
        harness.exerciseOptions(seriesId, exercised, HOLDER, payment, 0);

        DerivativeTypes.OptionSeries memory mid = harness.getOptionSeries(seriesId);
        assertEq(mid.remaining, notional - exercised);
        assertEq(mid.collateralLocked, requiredStrike - strikeOut);
        assertEq(harness.lockedCollateral(positionKey, 2), requiredStrike - strikeOut);
        assertEq(strike.balanceOf(HOLDER), strikeOut);
        assertEq(harness.principalOf(1, positionKey), makerUnderlyingBefore + payment);
        assertEq(harness.principalOf(2, positionKey), makerStrikeBefore - strikeOut);

        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, false, true);
        emit Reclaimed(seriesId, positionKey, notional - exercised, requiredStrike - strikeOut);
        vm.prank(MAKER);
        harness.reclaimOptions(seriesId);

        DerivativeTypes.OptionSeries memory done = harness.getOptionSeries(seriesId);
        assertTrue(done.reclaimed);
        assertEq(done.remaining, 0);
        assertEq(done.collateralLocked, 0);
        assertEq(harness.lockedCollateral(positionKey, 2), 0);
    }

    function test_exerciseOptionsFor_requiresHolderOrOperatorApproval() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        (uint256 positionId,, uint256 notional,) = _seedMakerState(1e18);
        DerivativeTypes.CreateOptionSeriesParams memory params = _defaultSeriesParams(positionId, notional, true);
        vm.prank(MAKER);
        uint256 seriesId = harness.createOptionSeries(params);

        uint256 exercised = 2e17;
        vm.prank(MAKER);
        optionToken.safeTransferFrom(MAKER, HOLDER, seriesId, exercised, "");

        uint256 payment = harness.previewExercisePayment(seriesId, exercised);
        strike.mint(HOLDER, payment);
        vm.prank(HOLDER);
        strike.approve(address(harness), payment);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Options_NotTokenHolder.selector, OPERATOR, seriesId));
        harness.exerciseOptionsFor(seriesId, exercised, HOLDER, HOLDER, payment, 0);

        vm.prank(HOLDER);
        optionToken.setApprovalForAll(OPERATOR, true);

        vm.prank(OPERATOR);
        harness.exerciseOptionsFor(seriesId, exercised, HOLDER, HOLDER, payment, 0);
        assertEq(underlying.balanceOf(HOLDER), exercised);
    }

    function test_optionExerciseInputValidation_andReclaimedGuard() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        vm.expectRevert(abi.encodeWithSelector(Options_InvalidSeries.selector, 999));
        harness.previewExercisePayment(999, 1);

        (uint256 positionId,, uint256 notional,) = _seedMakerState(1e18);
        DerivativeTypes.CreateOptionSeriesParams memory params = _defaultSeriesParams(positionId, notional, true);
        vm.prank(MAKER);
        uint256 seriesId = harness.createOptionSeries(params);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidAmount.selector, 0));
        harness.exerciseOptions(seriesId, 0, HOLDER, 0, 0);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidRecipient.selector, address(0)));
        harness.exerciseOptions(seriesId, 1, address(0), type(uint256).max, 0);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidRecipient.selector, address(0)));
        harness.exerciseOptionsFor(seriesId, 1, address(0), HOLDER, type(uint256).max, 0);

        vm.warp(block.timestamp + 2 days);
        vm.prank(MAKER);
        harness.reclaimOptions(seriesId);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_Reclaimed.selector, seriesId));
        harness.exerciseOptions(seriesId, 1, HOLDER, type(uint256).max, 0);
    }

    function test_createOptionSeries_validationMatrix() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        (uint256 positionId,, uint256 notional,) = _seedMakerState(1e18);
        DerivativeTypes.CreateOptionSeriesParams memory params = _defaultSeriesParams(positionId, notional, true);

        params.contractSize = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidContractSize.selector, 0));
        harness.createOptionSeries(params);

        params = _defaultSeriesParams(positionId, notional, true);
        params.strikePrice = 0;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidPrice.selector, 0));
        harness.createOptionSeries(params);

        params = _defaultSeriesParams(positionId, notional, true);
        params.expiry = uint64(block.timestamp);
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidExpiry.selector, uint64(block.timestamp)));
        harness.createOptionSeries(params);

        params = _defaultSeriesParams(positionId, notional, true);
        params.strikePoolId = params.underlyingPoolId;
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidPool.selector, 1));
        harness.createOptionSeries(params);
    }

    function test_createOptionSeries_revertsWhenPoolMembershipMissing() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        (uint256 positionIdA, bytes32 keyA, uint256 notionalA,) = _seedPositionPoolsNoJoin(MAKER, 1e18);
        harness.joinPool(keyA, 1);

        DerivativeTypes.CreateOptionSeriesParams memory paramsA = _defaultSeriesParams(positionIdA, notionalA, true);
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, keyA, 2));
        harness.createOptionSeries(paramsA);

        (uint256 positionIdB, bytes32 keyB, uint256 notionalB,) = _seedPositionPoolsNoJoin(MAKER, 1e18);
        harness.joinPool(keyB, 2);

        DerivativeTypes.CreateOptionSeriesParams memory paramsB = _defaultSeriesParams(positionIdB, notionalB, true);
        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, keyB, 1));
        harness.createOptionSeries(paramsB);
    }

    function test_burnReclaimedOptionsClaims_negativePaths() public {
        vm.prank(OWNER);
        harness.setOptionToken(address(optionToken));

        (uint256 positionId,, uint256 notional,) = _seedMakerState(1e18);
        DerivativeTypes.CreateOptionSeriesParams memory params = _defaultSeriesParams(positionId, notional, true);
        vm.prank(MAKER);
        uint256 seriesId = harness.createOptionSeries(params);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_InvalidAmount.selector, 0));
        harness.burnReclaimedOptionsClaims(MAKER, seriesId, 0);

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(Options_NotReclaimed.selector, seriesId));
        harness.burnReclaimedOptionsClaims(MAKER, seriesId, 1);

        vm.warp(block.timestamp + 2 days);
        vm.prank(MAKER);
        harness.reclaimOptions(seriesId);

        uint256 makerBal = optionToken.balanceOf(MAKER, seriesId);
        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(Options_InsufficientBalance.selector, MAKER, makerBal + 1, makerBal)
        );
        harness.burnReclaimedOptionsClaims(MAKER, seriesId, makerBal + 1);
    }

    function _defaultSeriesParams(uint256 positionId, uint256 totalSize, bool isCall)
        internal
        view
        returns (DerivativeTypes.CreateOptionSeriesParams memory)
    {
        return DerivativeTypes.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: totalSize,
            contractSize: 1,
            isCall: isCall,
            isAmerican: true,
            useCustomFees: false,
            createFeeBps: 0,
            exerciseFeeBps: 0,
            reclaimFeeBps: 0
        });
    }

    function _seedMakerState(uint256 totalSize)
        internal
        returns (uint256 positionId, bytes32 positionKey, uint256 notional, uint256 requiredStrike)
    {
        notional = totalSize;
        requiredStrike = _strikeAmount(totalSize);

        positionId = nft.mint(MAKER, 1);
        positionKey = nft.getPositionKey(positionId);

        harness.seedPool(1, address(underlying), positionKey, notional + 1e18, notional + 1e18);
        harness.seedPool(2, address(strike), positionKey, requiredStrike + 1e12, requiredStrike + 1e12);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);
    }

    function _seedPositionPoolsNoJoin(address owner, uint256 totalSize)
        internal
        returns (uint256 positionId, bytes32 positionKey, uint256 notional, uint256 requiredStrike)
    {
        notional = totalSize;
        requiredStrike = _strikeAmount(totalSize);

        positionId = nft.mint(owner, 1);
        positionKey = nft.getPositionKey(positionId);

        harness.seedPool(1, address(underlying), positionKey, notional + 1e18, notional + 1e18);
        harness.seedPool(2, address(strike), positionKey, requiredStrike + 1e12, requiredStrike + 1e12);
    }

    function _strikeAmount(uint256 underlyingAmount) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(underlying.decimals());
        uint256 strikeScale = 10 ** uint256(strike.decimals());
        uint256 normalized = Math.mulDiv(underlyingAmount, STRIKE_PRICE, underlyingScale);
        return Math.mulDiv(normalized, strikeScale, 1e18);
    }
}
