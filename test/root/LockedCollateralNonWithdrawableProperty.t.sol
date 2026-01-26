// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

contract PositionManagementHarness is PositionManagementFacet {
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

    function setLocked(bytes32 positionKey, uint256 pid, uint256 amount) external {
        LibEncumbrance.position(positionKey, pid).directLocked = amount;
    }
}

contract LockedCollateralNonWithdrawablePropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 9: Locked Collateral Non-Withdrawability
    function testFuzz_lockedCollateralBlocksWithdraw(
        uint256 principal,
        uint256 locked,
        uint256 withdrawAmount
    ) public {
        vm.assume(principal > 0);
        vm.assume(locked > 0);
        vm.assume(locked <= principal);
        uint256 available = principal - locked;
        vm.assume(withdrawAmount > available);
        vm.assume(withdrawAmount <= principal);

        MockERC20 token = new MockERC20("Mock", "MOCK", 18, 0);
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness facet = new PositionManagementHarness();

        nft.setMinter(address(this));
        address owner = address(0xBEEF);
        uint256 tokenId = nft.mint(owner, 1);
        facet.setPositionNFT(address(nft));

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.seedPool(1, address(token), principal);
        facet.setUser(1, positionKey, principal);
        facet.joinPool(1, positionKey);
        facet.setLocked(positionKey, 1, locked);

        token.mint(address(facet), principal);

        vm.expectRevert();
        vm.prank(owner);
        facet.withdrawFromPosition(tokenId, 1, withdrawAmount);
    }
}
