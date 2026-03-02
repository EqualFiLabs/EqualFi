// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "src/EqualX/MamCurveCreationFacet.sol";
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
import {ICurveProfile} from "src/interfaces/ICurveProfile.sol";
import "src/libraries/MamCurveErrors.sol";

contract FixedPriceProfile is ICurveProfile {
    uint256 internal immutable fixedPrice;

    constructor(uint256 fixedPrice_) {
        fixedPrice = fixedPrice_;
    }

    function computePrice(uint256, uint256, uint256, uint256, uint256, bytes32)
        external
        view
        returns (uint256 price)
    {
        return fixedPrice;
    }
}

contract MamCurveCommitBoundHarness is MamCurveCreationFacet, MamCurveExecutionFacet, MamCurveViewFacet {
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

contract MamCurveCommitBoundPropertyTest is Test {
    MamCurveCommitBoundHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    function setUp() public {
        harness = new MamCurveCommitBoundHarness();
        harness.setOwner(address(this));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);
        harness.configurePositionNFT(address(nft));
        vm.warp(1 days);
    }

    // Property 1: Generation mismatch reverts swap
    function testFuzz_generationMismatchRevertsSwap(uint8 bump) public {
        bump = uint8(bound(bump, 1, type(uint8).max));

        uint256 curveId = _createLinearCurve(address(0), bytes32(0), 7);
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);
        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);

        tokenB.mint(taker, maxQuote);
        vm.startPrank(taker);
        tokenB.approve(address(harness), maxQuote);
        uint32 wrongGeneration = curve.generation + uint32(bump);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_GenerationMismatch.selector, wrongGeneration, curve.generation));
        harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            1,
            uint64(block.timestamp + 1 days),
            taker,
            wrongGeneration,
            curve.commitment
        );
        vm.stopPrank();
    }

    // Property 2: Commitment mismatch reverts swap
    function testFuzz_commitmentMismatchRevertsSwap(bytes32 wrongCommitment) public {
        uint256 curveId = _createLinearCurve(address(0), bytes32(0), 8);
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);
        vm.assume(wrongCommitment != curve.commitment);

        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, maxQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), maxQuote);
        vm.expectRevert(abi.encodeWithSelector(MamCurve_CommitmentMismatch.selector, wrongCommitment, curve.commitment));
        harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            1,
            uint64(block.timestamp + 1 days),
            taker,
            curve.generation,
            wrongCommitment
        );
        vm.stopPrank();
    }

    // Property 3: Matching generation and commitment allows swap
    function test_matchingGenerationAndCommitmentAllowsSwap() public {
        uint256 curveId = _createLinearCurve(address(0), bytes32(0), 9);
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);

        uint256 amountIn = 2e18;
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, maxQuote);

        vm.startPrank(taker);
        tokenB.approve(address(harness), maxQuote);
        uint256 amountOut = harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            1,
            uint64(block.timestamp + 1 days),
            taker,
            curve.generation,
            curve.commitment
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "swap should succeed with matching expected values");
    }

    // Property 11: Swap execution uses stored profile for pricing
    function test_swapExecutionUsesStoredProfileForPricing() public {
        FixedPriceProfile profile = new FixedPriceProfile(4e18);
        harness.approveCurveProfile(address(profile));

        uint256 curveId = _createLinearCurve(address(profile), bytes32(uint256(123)), 10);
        MamTypes.StoredCurve memory curve = harness.getStoredCurve(curveId);

        uint256 amountIn = 2e18;
        uint256 expectedOut = 5e17; // amountIn * 1e18 / 4e18
        uint256 maxQuote = harness.previewCurveQuote(curveId, amountIn);
        tokenB.mint(taker, maxQuote);

        uint256 takerBaseBefore = tokenA.balanceOf(taker);
        vm.startPrank(taker);
        tokenB.approve(address(harness), maxQuote);
        uint256 amountOut = harness.executeCurveSwap(
            curveId,
            amountIn,
            maxQuote,
            expectedOut,
            uint64(block.timestamp + 1 days),
            taker,
            curve.generation,
            curve.commitment
        );
        vm.stopPrank();

        assertEq(amountOut, expectedOut, "amountOut must use profile-computed price");
        assertEq(tokenA.balanceOf(taker) - takerBaseBefore, expectedOut, "base delivered must match profile pricing");
    }

    function _createLinearCurve(address profile, bytes32 profileParams, uint96 salt) internal returns (uint256 curveId) {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 positionKey = nft.getPositionKey(makerTokenId);

        harness.seedPool(1, address(tokenA), positionKey, 5e18, 5e18);
        harness.seedPool(2, address(tokenB), positionKey, 5e18, 5e18);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: positionKey,
            makerPositionId: makerTokenId,
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
            profile: profile,
            profileParams: profileParams
        });

        vm.prank(maker);
        curveId = harness.createCurve(desc);
    }
}
