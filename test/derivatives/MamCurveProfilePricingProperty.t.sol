// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamCurveCreationFacet} from "src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveViewFacet} from "src/views/MamCurveViewFacet.sol";
import {MamTypes} from "src/libraries/MamTypes.sol";
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

contract ParametricPriceProfile is ICurveProfile {
    function computePrice(uint256, uint256, uint256, uint256, uint256, bytes32 profileParams)
        external
        pure
        returns (uint256 price)
    {
        return uint256(profileParams);
    }
}

contract RevertingPriceProfile is ICurveProfile {
    error RevertingPriceProfile_Boom();

    function computePrice(uint256, uint256, uint256, uint256, uint256, bytes32)
        external
        pure
        returns (uint256)
    {
        revert RevertingPriceProfile_Boom();
    }
}

contract MamCurveProfilePricingHarness is MamCurveCreationFacet, MamCurveViewFacet {
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
}

contract MamCurveProfilePricingPropertyTest is Test {
    MamCurveProfilePricingHarness internal harness;
    PositionNFT internal nft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    ParametricPriceProfile internal parametricProfile;
    RevertingPriceProfile internal revertingProfile;

    address internal maker = address(0xA11CE);

    function setUp() public {
        harness = new MamCurveProfilePricingHarness();
        harness.setOwner(address(this));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        tokenA = new MockERC20("TokenA", "A", 18, 0);
        tokenB = new MockERC20("TokenB", "B", 18, 0);

        parametricProfile = new ParametricPriceProfile();
        revertingProfile = new RevertingPriceProfile();
        harness.approveCurveProfile(address(parametricProfile));
        harness.approveCurveProfile(address(revertingProfile));

        harness.configurePositionNFT(address(nft));
        vm.warp(1 days);
    }

    // Property 14: View functions use stored profile for price computation
    function testFuzz_viewFunctionsUseStoredProfileForPrice(uint128 profilePrice, uint96 salt) public {
        profilePrice = uint128(bound(profilePrice, 1e12, 1e24));

        uint256 curveId = _createCurve(address(parametricProfile), bytes32(uint256(profilePrice)), salt);

        (, , , uint256 currentPrice, , , , , , ) = harness.getCurveStatus(curveId);
        assertEq(currentPrice, profilePrice, "getCurveStatus should use profile price");

        (uint256 amountOut, uint256 feeAmount, uint256 totalQuote, uint128 remainingVolume, bool ok) =
            harness.quoteCurveExactIn(curveId, profilePrice);
        assertTrue(ok, "quoteCurveExactIn should succeed");
        assertEq(amountOut, 1e18, "quoteCurveExactIn should use profile price");
        assertEq(feeAmount, 0, "fee should be zero");
        assertEq(totalQuote, profilePrice, "total quote mismatch");
        assertEq(remainingVolume, 2e18, "remaining volume mismatch");
    }

    function test_quoteCurvesExactInBatchContinuesOnProfileRevert() public {
        uint256 okCurveId = _createCurve(address(parametricProfile), bytes32(uint256(2e18)), 100);
        uint256 badCurveId = _createCurve(address(revertingProfile), bytes32(0), 101);

        uint256[] memory curveIds = new uint256[](3);
        uint256[] memory amountIns = new uint256[](3);
        curveIds[0] = okCurveId;
        curveIds[1] = badCurveId;
        curveIds[2] = okCurveId;
        amountIns[0] = 2e18;
        amountIns[1] = 2e18;
        amountIns[2] = 2e18;

        (uint256[] memory amountOuts, uint256[] memory feeAmounts, bool[] memory oks) =
            harness.quoteCurvesExactInBatch(curveIds, amountIns);

        assertEq(amountOuts[0], 1e18, "first quote amountOut mismatch");
        assertEq(feeAmounts[0], 0, "first quote fee mismatch");
        assertTrue(oks[0], "first quote should be ok");

        assertEq(amountOuts[1], 0, "failing quote amountOut should be zero");
        assertEq(feeAmounts[1], 0, "failing quote fee should be zero");
        assertFalse(oks[1], "failing quote should be marked not ok");

        assertEq(amountOuts[2], 1e18, "third quote amountOut mismatch");
        assertEq(feeAmounts[2], 0, "third quote fee mismatch");
        assertTrue(oks[2], "third quote should be ok");
    }

    function test_quoteCurveExactInPropagatesProfileRevert() public {
        uint256 badCurveId = _createCurve(address(revertingProfile), bytes32(0), 102);
        vm.expectRevert(RevertingPriceProfile.RevertingPriceProfile_Boom.selector);
        harness.quoteCurveExactIn(badCurveId, 2e18);
    }

    function _createCurve(address profile, bytes32 profileParams, uint96 salt) internal returns (uint256 curveId) {
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
