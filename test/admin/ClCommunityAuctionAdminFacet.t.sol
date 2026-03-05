// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClCommunityAuctionAdminFacet} from "../../src/admin/ClCommunityAuctionAdminFacet.sol";
import {ClCommunityAuctionFacet} from "../../src/EqualX/ClCommunityAuctionFacet.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibClAuctionStorage} from "../../src/libraries/LibClAuctionStorage.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {
    ClAuction_InvalidTickSpacing,
    ClAuction_CreationDisabled
} from "../../src/libraries/ClAuctionErrors.sol";

contract ClCommunityAuctionAdminHarness is ClCommunityAuctionAdminFacet, ClCommunityAuctionFacet {
    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function seedPool(uint256 pid, address token, bytes32 positionKey, uint256 principal, uint256 tracked) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = token;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;

        if (p.feeIndex == 0) p.feeIndex = LibFeeIndex.INDEX_SCALE;
        if (p.maintenanceIndex == 0) p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        if (p.activeCreditIndex == 0) p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;

        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function getClConfig() external view returns (bool creationEnabled, bool swapPaused, uint24 swapFeeCap) {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        return (cs.creationEnabled, cs.swapPaused, cs.swapFeeCap);
    }

    function isTickSpacingAllowed(uint24 tickSpacing) external view returns (bool) {
        return LibClAuctionStorage.s().allowedTickSpacings[tickSpacing];
    }
}

contract ClCommunityAuctionAdminFacetTest is Test {
    event ClCreationEnabledUpdated(bool enabled);
    event ClSwapFeeCapUpdated(uint24 maxFeePips);
    event ClTickSpacingAllowedUpdated(uint24 tickSpacing, bool allowed);
    event ClSwapPausedUpdated(bool paused);

    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant USER = address(0xCAFE);

    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;

    ClCommunityAuctionAdminHarness internal facet;
    PositionNFT internal positionNft;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal positionId;

    function setUp() public {
        facet = new ClCommunityAuctionAdminHarness();
        facet.setContractOwner(OWNER);
        facet.setTimelock(TIMELOCK);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        facet.configurePositionNFT(address(positionNft));

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);

        positionId = positionNft.mint(OWNER, POOL_A);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        facet.seedPool(POOL_A, address(tokenA), positionKey, 1_000_000e18, 1_000_000e18);
        facet.seedPool(POOL_B, address(tokenB), positionKey, 1_000_000e18, 1_000_000e18);
    }

    function test_setters_ownerAndTimelock_canUpdateConfig() public {
        vm.expectEmit(false, false, false, true);
        emit ClCreationEnabledUpdated(true);
        vm.prank(OWNER);
        facet.setClCreationEnabled(true);

        vm.expectEmit(false, false, false, true);
        emit ClSwapFeeCapUpdated(4_200);
        vm.prank(TIMELOCK);
        facet.setClSwapFeeCap(4_200);

        vm.expectEmit(true, false, false, true);
        emit ClTickSpacingAllowedUpdated(60, true);
        vm.prank(OWNER);
        facet.setClTickSpacingAllowed(60, true);

        vm.expectEmit(false, false, false, true);
        emit ClSwapPausedUpdated(true);
        vm.prank(TIMELOCK);
        facet.setClSwapPaused(true);

        (bool creationEnabled, bool swapPaused, uint24 swapFeeCap) = facet.getClConfig();
        assertTrue(creationEnabled);
        assertTrue(swapPaused);
        assertEq(swapFeeCap, 4_200);
        assertTrue(facet.isTickSpacingAllowed(60));
    }

    function test_setters_nonGovernance_revert() public {
        vm.prank(USER);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setClCreationEnabled(true);

        vm.prank(USER);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setClSwapFeeCap(3_000);

        vm.prank(USER);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setClTickSpacingAllowed(60, true);

        vm.prank(USER);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        facet.setClSwapPaused(true);
    }

    function test_setClTickSpacingAllowed_zero_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InvalidTickSpacing.selector, 0));
        facet.setClTickSpacingAllowed(0, true);
    }

    function test_creationDisabled_blocksCreateClCommunityAuction() public {
        vm.prank(OWNER);
        facet.setClTickSpacingAllowed(60, true);

        vm.prank(OWNER);
        facet.setClCreationEnabled(false);

        vm.prank(OWNER);
        vm.expectRevert(ClAuction_CreationDisabled.selector);
        facet.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: positionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp + 1 hours),
                endTime: uint64(block.timestamp + 2 hours)
            })
        );
    }
}
