// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFacet} from "../../src/equallend/FlashLoanFacet.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FlashLoanGasHarness is FlashLoanFacet {
    function initPool(uint256 pid, address underlying, uint16 feeBps, uint256 trackedBalance) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.trackedBalance = trackedBalance;
        p.poolConfig.flashLoanFeeBps = feeBps;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
    }
}

contract FlashLoanReceiverMock {
    bytes32 internal constant FLASH_CALLBACK_SUCCESS = keccak256("IFlashLoanReceiver.onFlashLoan");

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external returns (bytes32) {
        MockERC20(token).approve(msg.sender, type(uint256).max);
        return FLASH_CALLBACK_SUCCESS;
    }
}

contract FlashLoanGasTest is Test {
    bytes32 internal constant POINTS_STORAGE_POSITION = keccak256("equallend.points.storage");

    MockERC20 internal token;
    FlashLoanGasHarness internal facet;
    FlashLoanReceiverMock internal receiver;

    uint256 internal constant PID = 1;
    uint256 internal constant LOAN_AMOUNT = 1000 ether;
    uint16 internal constant FEE_BPS = 10;

    function setUp() public {
        token = new MockERC20("Token", "TOK", 18, 5_000_000 ether);
        facet = new FlashLoanGasHarness();
        receiver = new FlashLoanReceiverMock();

        facet.initPool(PID, address(token), FEE_BPS, LOAN_AMOUNT);
        _configurePointsIfEnabled();
        token.mint(address(facet), LOAN_AMOUNT);
        token.mint(address(receiver), 1 ether);
    }

    function test_gas_FlashLoan() public {
        vm.resumeGasMetering();
        facet.flashLoan(PID, address(receiver), LOAN_AMOUNT, bytes(""), facet.previewFlashLoanRepayment(PID, LOAN_AMOUNT));
    }

    function _configurePointsIfEnabled() internal {
        if (!vm.envOr("POINTS_ON_GAS", false)) return;
        _setPoints(address(facet), LibPoints.ACTION_FLASH_LOAN, 1);
    }

    function _setPoints(address target, bytes32 actionType, uint256 amount) internal {
        bytes32 pointsPerActionSlot = bytes32(uint256(POINTS_STORAGE_POSITION) + 1);
        bytes32 valueSlot = keccak256(abi.encode(actionType, pointsPerActionSlot));
        vm.store(target, valueSlot, bytes32(amount));
    }
}
