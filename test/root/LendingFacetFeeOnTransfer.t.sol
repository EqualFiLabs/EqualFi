// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {FeeOnTransferERC20} from "../../src/mocks/FeeOnTransferERC20.sol";

/// @notice Minimal harness to drive LendingFacet with configurable underlying
contract LendingFacetFoTHarness is LendingFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint256 minTopup,
        uint16 ltvBps,
        uint16 rollingApy
    ) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.minTopupAmount = minTopup;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.poolConfig.rollingApyBps = rollingApy;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
    }

    function addFixedConfig(uint256 pid, uint40 durationSecs, uint16 apyBps) external {
        s().pools[pid].poolConfig.fixedTermConfigs.push(
            Types.FixedTermConfig({durationSecs: durationSecs, apyBps: apyBps})
        );
    }

    function mintFor(address to, uint256 pid) external returns (uint256) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).mint(to, pid);
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }

    function rollingLoan(uint256 pid, bytes32 key) external view returns (Types.RollingCreditLoan memory) {
        return s().pools[pid].rollingLoans[key];
    }

}

/// @notice Unit tests covering FoT repayment accounting
contract LendingFacetFeeOnTransferTest is Test {
    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    PositionNFT internal nft;
    LendingFacetFoTHarness internal facet;
    FeeOnTransferERC20 internal token;
    address internal user = address(0xA11CE);

    function setUp() public {
        token = new FeeOnTransferERC20("Fee Token", "FEE", 18, INITIAL_SUPPLY, 1000, address(0xFEE));
        nft = new PositionNFT();
        facet = new LendingFacetFoTHarness();
        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, 1, LTV_BPS, 1000);
        facet.addFixedConfig(PID, 30 days, 1000);

        token.transfer(user, INITIAL_SUPPLY / 2);
        token.mint(address(facet), INITIAL_SUPPLY / 4); // seed pool liquidity to mirror storage snapshotting
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function _seedPosition(uint256 amount) internal returns (uint256 tokenId, bytes32 key) {
        vm.prank(user);
        tokenId = facet.mintFor(user, PID);
        key = nft.getPositionKey(tokenId);
        facet.seedPosition(PID, key, amount);
    }

    function test_makePaymentCreditsNetReceived() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether); // trackedBalance -> 80
        uint256 sinkBefore = token.balanceOf(address(0xFEE));
        facet.makePaymentFromPosition(tokenId, PID, 10 ether); // net received 9 ether
        vm.stopPrank();

        assertEq(facet.trackedBalance(PID), 89 ether, "trackedBalance uses net");
        assertEq(facet.rollingLoan(PID, key).principalRemaining, 11 ether, "principal reduced by net principal portion");
        assertEq(token.balanceOf(address(0xFEE)) - sinkBefore, 1 ether, "fee sink credited");
    }

    function test_makePaymentAcceptsSmallNetAmount() public {
        (uint256 tokenId, bytes32 key) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        facet.makePaymentFromPosition(tokenId, PID, 1 ether);
        vm.stopPrank();

        assertEq(facet.rollingLoan(PID, key).principalRemaining, 19.1 ether, "principal reduced by net amount");
    }

    function test_closeRollingRevertsWithFeeOnTransfer() public {
        (uint256 tokenId,) = _seedPosition(100 ether);

        vm.startPrank(user);
        facet.openRollingFromPosition(tokenId, PID, 20 ether);
        vm.expectRevert("PositionNFT: payoff underfunded");
        facet.closeRollingCreditFromPosition(tokenId, PID);
        vm.stopPrank();
    }

    function test_repayFixedRevertsWithFeeOnTransfer() public {
        (uint256 tokenId,) = _seedPosition(100 ether);

        vm.startPrank(user);
        uint256 loanId = facet.openFixedFromPosition(tokenId, PID, 20 ether, 0);
        vm.expectRevert("PositionNFT: repay underfunded");
        facet.repayFixedFromPosition(tokenId, PID, loanId, 10 ether);
        vm.stopPrank();
    }
}
