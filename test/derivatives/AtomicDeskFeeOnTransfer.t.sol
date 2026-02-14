// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";
import {AtomicDeskDiamondTestBase} from "./AtomicDeskIntegration.t.sol";

contract AtomicDeskFeeOnTransferTest is AtomicDeskDiamondTestBase {
    FeeOnTransferERC20 internal feeToken;
    address internal feeSink = address(0xFEE);

    function setUp() public {
        setUpDiamond();
        feeToken = new FeeOnTransferERC20("TokenA", "TKA", 18, 0, 500, feeSink); // 5%
        tokenA = feeToken;
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);
    }

    function testSettleFoTMinReceivedSucceeds() public {
        (bytes32 deskId, bytes32 positionKey,) = _createDesk(true);
        uint256 amount = 3e18;
        bytes32 reservationId = _reserve(deskId, address(tokenA), amount);

        bytes32 tau = keccak256("tau");
        bytes32 hashlock = keccak256(abi.encodePacked(tau));
        vm.prank(maker);
        escrow.setHashlock(reservationId, hashlock);

        uint256 fee = (amount * feeToken.feeBps()) / 10_000;
        uint256 minReceived = amount - fee;

        uint256 sinkBefore = feeToken.balanceOf(feeSink);
        uint256 takerBefore = feeToken.balanceOf(taker);

        vm.prank(maker);
        escrow.settle(reservationId, tau, minReceived);

        assertEq(feeToken.balanceOf(taker) - takerBefore, minReceived, "taker net received");
        assertEq(feeToken.balanceOf(feeSink) - sinkBefore, fee, "fee sink credited");
        assertEq(harness.getPrincipal(POOL_A, positionKey), PRINCIPAL - amount, "principal reduced");
    }
}
