// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import "../../src/libraries/Errors.sol";

contract EncumbranceWithdrawHarness is PositionManagementFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function seedPool(uint256 pid, address underlying, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.withdrawFee = Types.ActionFeeConfig(0, false);
    }

    function setUser(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(uint256 pid, bytes32 positionKey) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function setEncumbered(bytes32 positionKey, uint256 pid, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.encumber(positionKey, pid, indexId, amount);
    }
}

contract IndexEncumbranceBlocksWithdrawalPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 5: Encumbrance Blocks Withdrawal
    function testFuzz_indexEncumbranceBlocksWithdraw(
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

        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        PositionNFT nft = new PositionNFT();
        EncumbranceWithdrawHarness facet = new EncumbranceWithdrawHarness();

        nft.setMinter(address(this));
        address owner = address(0xBEEF);
        uint256 tokenId = nft.mint(owner, 1);
        facet.setPositionNFT(address(nft));

        bytes32 positionKey = nft.getPositionKey(tokenId);
        uint256 pid = 1;
        facet.seedPool(pid, address(token), principal);
        facet.setUser(pid, positionKey, principal);
        facet.joinPool(pid, positionKey);
        facet.setEncumbered(positionKey, pid, 7, encumbered);

        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, withdrawAmount, available));
        vm.prank(owner);
        facet.withdrawFromPosition(tokenId, pid, withdrawAmount);
    }
}
