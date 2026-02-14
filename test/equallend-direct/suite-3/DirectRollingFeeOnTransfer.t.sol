// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {FeeOnTransferERC20} from "../../../src/mocks/FeeOnTransferERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";

contract DirectRollingFeeOnTransferTest is DirectDiamondTestBase {
    FeeOnTransferERC20 internal token;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal feeSink = address(0xFEE);

    function setUp() public {
        setUpDiamond();

        token = new FeeOnTransferERC20("Fee Token", "FEE", 18, 0, 500, feeSink); // 5%

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);

        DirectTypes.DirectRollingConfig memory rollingCfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 604_800,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
        harness.setRollingConfig(rollingCfg);

        uint256 lenderPos = nft.mint(lenderOwner, 1);
        uint256 borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(1, address(token), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(token), borrowerKey, 200 ether, true);

        token.mint(lenderOwner, 500 ether);
        token.mint(borrowerOwner, 200 ether);

        vm.prank(lenderOwner);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        token.approve(address(diamond), type(uint256).max);
    }

    function _gross(uint256 netAmount) internal view returns (uint256) {
        uint256 feeBps = token.feeBps();
        return Math.mulDiv(netAmount, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
    }

    function _net(uint256 grossAmount) internal view returns (uint256) {
        uint256 fee = (grossAmount * token.feeBps()) / 10_000;
        return grossAmount - fee;
    }

    function testRollingPayment_acceptsFoT() public {
        DirectTypes.DirectRollingOfferParams memory params = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: 1,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 800,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 520,
            upfrontPremium: 5 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);

        uint256 minReceivedLender = _net(params.upfrontPremium);
        uint256 netToBorrower = params.principal - params.upfrontPremium;
        uint256 minReceivedBorrower = _net(netToBorrower);

        vm.prank(borrowerOwner);
        uint256 agreementId = rollingAgreements.acceptRollingOffer(
            offerId,
            2,
            minReceivedLender,
            minReceivedBorrower
        );

        uint256 payNet = 10 ether;
        uint256 maxPayment = _gross(payNet);
        uint256 minReceived = _net(payNet);
        uint256 sinkBefore = token.balanceOf(feeSink);

        vm.prank(borrowerOwner);
        rollingPayments.makeRollingPayment(agreementId, payNet, maxPayment, minReceived);

        assertGt(token.balanceOf(feeSink), sinkBefore, "fee charged");
    }
}
