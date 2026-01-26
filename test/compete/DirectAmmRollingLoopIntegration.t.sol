// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {DirectDiamondTestBase} from "../equallend-direct/DirectDiamondTestBase.sol";

interface IPositionManagement {
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
}

contract DirectAmmRollingLoopIntegrationTest is DirectDiamondTestBase {
    IPositionManagement internal pm;
    AmmAuctionFacet internal amm;
    MockERC20 internal token1;
    MockERC20 internal token2;

    address internal userA = address(0xA11CE);
    address internal userB = address(0xB0B);
    address internal userC = address(0xC0DE);

    uint256 internal aPositionId;
    uint256 internal bPositionId;
    uint256 internal cPositionId;

    uint256 internal constant POOL_TOKEN1 = 1;
    uint256 internal constant POOL_TOKEN2 = 2;
    uint16 internal constant LTV_BPS = 8000;

    uint256 internal constant BORROW_AMOUNT = 2_000 ether;
    uint256 internal constant PRICE_DENOMINATOR = 3500;

    function setUp() public {
        setUpDiamond();
        _addPositionManagementFacet();
        _addAmmFacet();
        pm = IPositionManagement(address(diamond));
        amm = AmmAuctionFacet(address(diamond));

        token1 = new MockERC20("Token1", "TK1", 18, 1_000_000 ether);
        token2 = new MockERC20("Token2", "TK2", 18, 1_000_000 ether);

        finalizePositionNFT();

        harness.initPool(POOL_TOKEN1, address(token1), 0, 0, LTV_BPS);
        harness.initPool(POOL_TOKEN2, address(token2), 0, 0, LTV_BPS);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);

        DirectTypes.DirectRollingConfig memory rollingCfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 1,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
        harness.setRollingConfig(rollingCfg);

        token1.transfer(userA, 2 ether);
        token1.transfer(userC, 10 ether);
        token2.transfer(userB, 50_000 ether);
        token2.transfer(userC, 20_000 ether);

        vm.startPrank(userA);
        token1.approve(address(diamond), type(uint256).max);
        token2.approve(address(diamond), type(uint256).max);
        aPositionId = pm.mintPositionWithDeposit(POOL_TOKEN1, 2 ether);
        vm.stopPrank();

        vm.startPrank(userB);
        token2.approve(address(diamond), type(uint256).max);
        bPositionId = pm.mintPositionWithDeposit(POOL_TOKEN2, 50_000 ether);
        vm.stopPrank();

        vm.startPrank(userC);
        token1.approve(address(diamond), type(uint256).max);
        token2.approve(address(diamond), type(uint256).max);
        cPositionId = pm.mintPositionWithDeposit(POOL_TOKEN1, 10 ether);
        pm.depositToPosition(cPositionId, POOL_TOKEN2, 20_000 ether);
        vm.stopPrank();
    }

    function test_LoopRollingOfferSwapAndDeposit() public {
        uint256 auctionId = _createAmmAuction();
        bytes32 aKey = nft.getPositionKey(aPositionId);

        uint256 collateralPerFill = Math.mulDiv(BORROW_AMOUNT, 1, PRICE_DENOMINATOR);
        uint256 principalBefore = views.getUserPrincipal(POOL_TOKEN1, aKey);

        for (uint256 i = 0; i < 3; i++) {
            uint256 offerId = _postRollingOffer(collateralPerFill);

            vm.prank(userA);
            rollingAgreements.acceptRollingOffer(offerId, aPositionId);

            vm.prank(userA);
            uint256 amountOut = amm.swapExactIn(auctionId, address(token2), BORROW_AMOUNT, 0, userA);
            assertGt(amountOut, 0, "swap output");

            vm.prank(userA);
            pm.depositToPosition(aPositionId, POOL_TOKEN1, amountOut);

            uint256 locked = views.directLocked(aKey, POOL_TOKEN1);
            assertEq(locked, collateralPerFill * (i + 1), "locked collateral");
        }

        uint256 principalAfter = views.getUserPrincipal(POOL_TOKEN1, aKey);
        assertGt(principalAfter, principalBefore, "principal grows via loop");
    }

    function _createAmmAuction() internal returns (uint256 auctionId) {
        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: cPositionId,
            poolIdA: POOL_TOKEN1,
            poolIdB: POOL_TOKEN2,
            reserveA: 5 ether,
            reserveB: 16_000 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 7 days),
            feeBps: 0,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        vm.prank(userC);
        auctionId = amm.createAuction(params);
    }

    function _postRollingOffer(uint256 collateralLockAmount) internal returns (uint256 offerId) {
        DirectTypes.DirectRollingOfferParams memory params = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: bPositionId,
            lenderPoolId: POOL_TOKEN2,
            collateralPoolId: POOL_TOKEN1,
            collateralAsset: address(token1),
            borrowAsset: address(token2),
            principal: BORROW_AMOUNT,
            collateralLockAmount: collateralLockAmount,
            paymentIntervalSeconds: 30 days,
            rollingApyBps: 100,
            gracePeriodSeconds: 1 days,
            maxPaymentCount: 2,
            upfrontPremium: 0,
            allowAmortization: false,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });

        vm.prank(userB);
        offerId = rollingOffers.postRollingOffer(params);
    }

    function _addPositionManagementFacet() internal {
        PositionManagementFacet pmFacet = new PositionManagementFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = _cut(address(pmFacet), _selectorsPositionManagement());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _addAmmFacet() internal {
        AmmAuctionFacet ammFacet = new AmmAuctionFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = _cut(address(ammFacet), _selectorsAmm());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
    }

    function _selectorsAmm() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactIn.selector;
        s[3] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[4] = AmmAuctionFacet.finalizeAuction.selector;
        s[5] = AmmAuctionFacet.cancelAuction.selector;
        s[6] = AmmAuctionFacet.getAuction.selector;
        s[7] = AmmAuctionFacet.previewSwap.selector;
    }
}
