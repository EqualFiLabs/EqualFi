// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {UnexpectedMsgValue, NativeTransferFailed} from "../../src/libraries/Errors.sol";

contract PositionManagementNativeHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
    }
}

contract PositionRevertingReceiver {
    PositionManagementNativeHarness internal facet;
    uint256 internal tokenId;
    uint256 internal pid;

    constructor(PositionManagementNativeHarness facet_, uint256 pid_, uint256 depositAmount) {
        facet = facet_;
        pid = pid_;
        tokenId = facet.mintPositionWithDeposit(pid, depositAmount);
    }

    function attemptWithdraw(uint256 amount) external {
        facet.withdrawFromPosition(tokenId, pid, amount);
    }

    receive() external payable {
        revert("nope");
    }
}

contract PositionManagementNativeEthPropertyTest is Test {
    PositionNFT internal nft;
    PositionManagementNativeHarness internal facet;
    MockERC20 internal token;

    address internal user = address(0xA11CE);
    uint256 internal constant PID = 1;

    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18, 0);
        nft = new PositionNFT();
        facet = new PositionManagementNativeHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, 8_000);
    }

    /// Feature: native-eth-support, Property 4: Stray ETH Rejection
    function testFuzz_strayEthRejectsDeposits(uint96 value) public {
        value = uint96(bound(uint256(value), 1, 10 ether));
        vm.deal(user, value);

        vm.prank(user);
        uint256 tokenId = facet.mintPosition(PID);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, value));
        facet.depositToPosition{value: value}(tokenId, PID, 1);
    }

    /// Feature: native-eth-support, Property 4: Stray ETH Rejection
    function testFuzz_strayEthRejectsWithdraws(uint96 value) public {
        value = uint96(bound(uint256(value), 1, 10 ether));
        vm.deal(user, value);

        vm.prank(user);
        uint256 tokenId = facet.mintPosition(PID);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, value));
        facet.withdrawFromPosition{value: value}(tokenId, PID, 1);
    }

    /// Feature: native-eth-support, Property 5: Native Transfer Failure Handling
    function test_nativeTransferFailureReverts() public {
        uint256 nativePid = 2;
        facet.initPool(nativePid, address(0), 1, 1, 8_000);
        vm.deal(address(facet), 1 ether);

        PositionRevertingReceiver receiver = new PositionRevertingReceiver(facet, nativePid, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NativeTransferFailed.selector, address(receiver), 1 ether));
        receiver.attemptWithdraw(1 ether);
    }
}
