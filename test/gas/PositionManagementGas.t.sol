// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract PositionManagementGasHarness is PositionManagementFacet {
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
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
    }
}

contract PositionManagementGasTest is Test {
    PositionNFT internal nft;
    PositionManagementGasHarness internal facet;
    MockERC20 internal token;

    address internal user = address(0xA11CE);
    uint256 internal constant PID = 1;

    function setUp() public {
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);
        nft = new PositionNFT();
        facet = new PositionManagementGasHarness();

        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));
        facet.initPool(PID, address(token), 1, 1, 8000);

        token.transfer(user, 1_000_000 ether / 2);
        vm.prank(user);
        token.approve(address(facet), type(uint256).max);
    }

    function test_gas_MintPositionWithDeposit() public {
        vm.prank(user);
        vm.resumeGasMetering();
        facet.mintPositionWithDeposit(PID, 10 ether);
    }
}
