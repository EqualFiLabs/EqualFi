// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {ClCommunityAuctionFacet} from "src/EqualX/ClCommunityAuctionFacet.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {
    ClAuction_CreationDisabled,
    ClAuction_NotActive,
    ClAuction_Unauthorized,
    ClAuction_InputAmountMismatch
} from "src/libraries/ClAuctionErrors.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibClAuctionStorage as ClStore} from "src/libraries/LibClAuctionStorage.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {Types} from "src/libraries/Types.sol";
import {ClPositionManager} from "src/nft/ClPositionManager.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

contract MockTBAAccount {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract Mock6551Registry is IERC6551Registry {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address accountAddress)
    {
        bytes32 deploySalt = _deploySalt(implementation, salt, chainId, tokenContract, tokenId);
        accountAddress = account(implementation, salt, chainId, tokenContract, tokenId);
        if (accountAddress.code.length == 0) {
            accountAddress = address(new MockTBAAccount{salt: deploySalt}());
        }
    }

    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        public
        view
        returns (address accountAddress)
    {
        bytes32 deploySalt = _deploySalt(implementation, salt, chainId, tokenContract, tokenId);
        accountAddress = Create2.computeAddress(deploySalt, keccak256(type(MockTBAAccount).creationCode), address(this));
    }

    function _deploySalt(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
    }
}

contract FeeOnTransferToken is ERC20 {
    uint256 internal constant FEE_BPS = 100; // 1%

    constructor() ERC20("FeeToken", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 receiveAmount = amount - fee;

        _transfer(from, to, receiveAmount);
        if (fee > 0) {
            _burn(from, fee);
        }
        return true;
    }
}

contract ClCommunityAuctionHarness is ClCommunityAuctionFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setAgentConfig(address registry, address implementation, bytes32 salt) external {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        ds.erc6551Registry = registry;
        ds.erc6551Implementation = implementation;
        ds.tbaSalt = salt;
    }

    function setClConfig(address manager, bool creationEnabled, bool swapPaused, uint24 swapFeeCap) external {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        cs.clPositionManager = manager;
        cs.creationEnabled = creationEnabled;
        cs.swapPaused = swapPaused;
        cs.swapFeeCap = swapFeeCap;
    }

    function setTickSpacingAllowed(uint24 tickSpacing, bool allowed) external {
        LibClAuctionStorage.s().allowedTickSpacings[tickSpacing] = allowed;
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

    function getClAuction(uint256 auctionId) external view returns (ClStore.ClCommunityAuction memory) {
        return ClStore.s().auctions[auctionId];
    }

    function getClPosition(uint256 clPositionId) external view returns (ClStore.ClPosition memory) {
        return ClStore.s().positions[clPositionId];
    }

    function getClEncumbranceLock(uint256 clPositionId) external view returns (ClStore.EncumbranceLock memory) {
        return ClStore.s().encumbranceLocks[clPositionId];
    }

    function getUserYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function getPoolYieldReserve(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }
}

contract ClCommunityAuctionFacetTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RANDO = address(0xBAD);
    address internal constant TRADER = address(0xCAFE);

    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;

    ClCommunityAuctionHarness internal facet;
    PositionNFT internal positionNft;
    ClPositionManager internal clManager;
    Mock6551Registry internal registry;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal sourcePositionId;
    bytes32 internal sourcePositionKey;

    function setUp() public {
        facet = new ClCommunityAuctionHarness();
        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));

        registry = new Mock6551Registry();
        clManager = new ClPositionManager(address(facet));

        facet.configurePositionNFT(address(positionNft));
        facet.setAgentConfig(address(registry), address(0xBEEF), keccak256("CL_TBA_SALT"));
        facet.setClConfig(address(clManager), true, false, 100_000);
        facet.setTickSpacingAllowed(60, true);

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);

        sourcePositionId = positionNft.mint(ALICE, POOL_A);
        sourcePositionKey = positionNft.getPositionKey(sourcePositionId);

        facet.seedPool(POOL_A, address(tokenA), sourcePositionKey, 2_000_000e18, 2_000_000e18);
        facet.seedPool(POOL_B, address(tokenB), sourcePositionKey, 2_000_000e18, 2_000_000e18);

        tokenA.mint(address(facet), 2_000_000e18);
        tokenB.mint(address(facet), 2_000_000e18);
    }

    function test_create_cancel_finalize_lifecycle() public {
        facet.setClConfig(address(clManager), false, false, 100_000);

        LibClAuctionStorage.CreateClAuctionParams memory p = LibClAuctionStorage.CreateClAuctionParams({
            positionId: sourcePositionId,
            poolIdA: POOL_A,
            poolIdB: POOL_B,
            tickSpacing: 60,
            swapFee: 3_000,
            sqrtPriceX96: 79228162514264337593543950336,
            startTime: uint64(block.timestamp + 1 hours),
            endTime: uint64(block.timestamp + 2 hours)
        });

        vm.prank(ALICE);
        vm.expectRevert(ClAuction_CreationDisabled.selector);
        facet.createClCommunityAuction(p);

        facet.setClConfig(address(clManager), true, false, 100_000);

        vm.prank(ALICE);
        uint256 auctionId = facet.createClCommunityAuction(p);

        LibClAuctionStorage.ClCommunityAuction memory auction = facet.getClAuction(auctionId);
        assertEq(auction.poolIdA, POOL_A);
        assertEq(auction.poolIdB, POOL_B);
        assertEq(auction.tokenA, address(tokenA));
        assertEq(auction.tokenB, address(tokenB));
        assertTrue(auction.initialized);
        assertFalse(auction.finalized);
        assertFalse(auction.cancelled);

        vm.prank(ALICE);
        facet.cancelClCommunityAuction(auctionId);
        auction = facet.getClAuction(auctionId);
        assertTrue(auction.cancelled);

        LibClAuctionStorage.CreateClAuctionParams memory p2 = p;
        p2.startTime = uint64(block.timestamp + 2 hours);
        p2.endTime = uint64(block.timestamp + 3 hours);

        vm.prank(ALICE);
        uint256 auctionId2 = facet.createClCommunityAuction(p2);

        vm.expectRevert(abi.encodeWithSelector(ClAuction_NotActive.selector, auctionId2));
        facet.finalizeClCommunityAuction(auctionId2);

        vm.warp(block.timestamp + 4 hours);
        facet.finalizeClCommunityAuction(auctionId2);
        auction = facet.getClAuction(auctionId2);
        assertTrue(auction.finalized);
    }

    function test_mint_increase_swap_collect_decrease_burn_flow() public {
        uint256 auctionId = _createActiveAuction();

        LibClAuctionStorage.MintClPositionParams memory mintP = LibClAuctionStorage.MintClPositionParams({
            auctionId: auctionId,
            positionId: sourcePositionId,
            tickLower: -120,
            tickUpper: 120,
            amount0Desired: 100e18,
            amount1Desired: 100e18,
            amount0Min: 0,
            amount1Min: 0
        });

        vm.prank(ALICE);
        (uint256 clPositionId, uint128 mintedLiquidity, uint256 amount0, uint256 amount1) = facet.mintClPosition(mintP);

        assertGt(mintedLiquidity, 0);
        assertGt(amount0 + amount1, 0);

        address expectedTba = registry.account(
            address(0xBEEF),
            keccak256("CL_TBA_SALT"),
            block.chainid,
            address(positionNft),
            sourcePositionId
        );
        assertEq(clManager.ownerOf(clPositionId), expectedTba);

        LibClAuctionStorage.EncumbranceLock memory lockState = facet.getClEncumbranceLock(clPositionId);
        assertGt(lockState.lockedA + lockState.lockedB, 0);

        vm.prank(ALICE);
        (uint128 liqAdded,,) = facet.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 50e18,
                amount1Desired: 50e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );
        assertGt(liqAdded, 0);

        tokenA.mint(TRADER, 200e18);
        vm.prank(TRADER);
        tokenA.approve(address(facet), type(uint256).max);

        vm.prank(TRADER);
        uint256 amountOut = facet.swapExactIn(auctionId, address(tokenA), 100e18, 0, TRADER);
        assertGt(amountOut, 0);

        uint256 yieldBeforeA = facet.getUserYield(POOL_A, sourcePositionKey);
        uint256 yieldBeforeB = facet.getUserYield(POOL_B, sourcePositionKey);

        vm.prank(ALICE);
        (uint256 collected0, uint256 collected1) = facet.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertGt(collected0 + collected1, 0);
        assertGe(facet.getUserYield(POOL_A, sourcePositionKey) - yieldBeforeA, collected0);
        assertGe(facet.getUserYield(POOL_B, sourcePositionKey) - yieldBeforeB, collected1);

        LibClAuctionStorage.ClPosition memory positionBeforeDecrease = facet.getClPosition(clPositionId);

        vm.prank(ALICE);
        facet.decreaseClLiquidity(
            LibClAuctionStorage.DecreaseClLiquidityParams({
                clPositionId: clPositionId,
                liquidity: positionBeforeDecrease.liquidity,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(ALICE);
        facet.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        vm.prank(ALICE);
        facet.burnClPosition(clPositionId);

        vm.expectRevert();
        clManager.ownerOf(clPositionId);

        lockState = facet.getClEncumbranceLock(clPositionId);
        assertEq(lockState.lockedA, 0);
        assertEq(lockState.lockedB, 0);
    }

    function test_authorization_owner_approved_tba_and_unauthorized() public {
        uint256 auctionId = _createActiveAuction();

        LibClAuctionStorage.MintClPositionParams memory mintP = LibClAuctionStorage.MintClPositionParams({
            auctionId: auctionId,
            positionId: sourcePositionId,
            tickLower: -120,
            tickUpper: 120,
            amount0Desired: 100e18,
            amount1Desired: 100e18,
            amount0Min: 0,
            amount1Min: 0
        });

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        facet.mintClPosition(mintP);

        vm.prank(ALICE);
        positionNft.approve(BOB, sourcePositionId);

        vm.prank(BOB);
        (uint256 clPositionId,,,) = facet.mintClPosition(mintP);

        address tba = registry.account(
            address(0xBEEF),
            keccak256("CL_TBA_SALT"),
            block.chainid,
            address(positionNft),
            sourcePositionId
        );

        vm.prank(tba);
        facet.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 10e18,
                amount1Desired: 10e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );
    }

    function test_swapExactIn_reverts_on_balance_delta_mismatch() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();

        uint256 feePoolA = 11;
        facet.seedPool(feePoolA, address(feeToken), sourcePositionKey, 2_000_000e18, 2_000_000e18);
        feeToken.mint(address(facet), 2_000_000e18);

        vm.prank(ALICE);
        uint256 auctionId = facet.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: feePoolA,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days)
            })
        );

        vm.prank(ALICE);
        facet.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        feeToken.mint(TRADER, 100e18);
        vm.prank(TRADER);
        feeToken.approve(address(facet), 100e18);

        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InputAmountMismatch.selector, 100e18, 99e18));
        facet.swapExactIn(auctionId, address(feeToken), 100e18, 0, TRADER);
    }

    function _createActiveAuction() internal returns (uint256 auctionId) {
        vm.prank(ALICE);
        auctionId = facet.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days)
            })
        );
    }
}
