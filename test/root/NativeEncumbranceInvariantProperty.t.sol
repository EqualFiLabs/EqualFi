// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {InsufficientPrincipal} from "../../src/libraries/Errors.sol";

contract NativeEncumbranceHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function seedNativePool(uint256 pid, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = address(0);
        p.initialized = true;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
    }

    function setUser(uint256 pid, bytes32 key, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[key] = principal;
        p.userFeeIndex[key] = p.feeIndex;
        p.userMaintenanceIndex[key] = p.maintenanceIndex;
    }

    function joinPool(uint256 pid, bytes32 key) external {
        LibPoolMembership._joinPool(key, pid);
    }

    function encumberIndex(bytes32 key, uint256 pid, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.encumber(key, pid, indexId, amount);
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }
}

contract NativeEncumbranceInvariantPropertyTest is Test {
    /// Feature: native-eth-support, Property 8: Encumbrance Invariant for Native ETH
    function testFuzz_nativeEncumbranceBlocksWithdrawal(
        uint256 principal,
        uint256 encumbered,
        uint256 withdrawAmount
    ) public {
        vm.assume(principal > 0);
        vm.assume(encumbered > 0);
        vm.assume(encumbered <= principal);
        uint256 available = principal - encumbered;
        vm.assume(withdrawAmount > available);
        vm.assume(withdrawAmount <= principal);

        NativeEncumbranceHarness facet = new NativeEncumbranceHarness();
        PositionNFT nft = new PositionNFT();
        facet.configurePositionNFT(address(nft));
        nft.setMinter(address(facet));

        address owner = address(0xBEEF);
        facet.seedNativePool(1, principal);
        vm.prank(owner);
        uint256 tokenId = facet.mintPosition(1);
        bytes32 key = nft.getPositionKey(tokenId);
        facet.setUser(1, key, principal);
        facet.joinPool(1, key);
        facet.encumberIndex(key, 1, 7, encumbered);

        facet.setNativeTrackedTotal(principal);
        vm.deal(address(facet), principal);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, withdrawAmount, available));
        facet.withdrawFromPosition(tokenId, 1, withdrawAmount);
    }
}
