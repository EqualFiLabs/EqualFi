// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {Diamond} from "src/core/Diamond.sol";
import {DiamondCutFacet} from "src/core/DiamondCutFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {ClCommunityAuctionFacet} from "src/EqualX/ClCommunityAuctionFacet.sol";
import {ClCommunityAuctionViewFacet} from "src/views/ClCommunityAuctionViewFacet.sol";
import {ClCommunityAuctionAdminFacet} from "src/admin/ClCommunityAuctionAdminFacet.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {ClPositionManager} from "src/nft/ClPositionManager.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

interface IClCommunityAuctionFacet {
    function createClCommunityAuction(LibClAuctionStorage.CreateClAuctionParams calldata p)
        external
        returns (uint256 auctionId);
    function cancelClCommunityAuction(uint256 auctionId) external;
    function finalizeClCommunityAuction(uint256 auctionId) external;

    function mintClPosition(LibClAuctionStorage.MintClPositionParams calldata p)
        external
        returns (uint256 clPositionId, uint128 liquidity, uint256 amountA, uint256 amountB);

    function increaseClLiquidity(LibClAuctionStorage.IncreaseClLiquidityParams calldata p)
        external
        returns (uint128 liquidity, uint256 amountA, uint256 amountB);

    function decreaseClLiquidity(LibClAuctionStorage.DecreaseClLiquidityParams calldata p)
        external
        returns (uint256 amountA, uint256 amountB);

    function collectClFees(LibClAuctionStorage.CollectClFeesParams calldata p)
        external
        returns (uint256 amountA, uint256 amountB);

    function burnClPosition(uint256 clPositionId) external;

    function swapExactIn(uint256 auctionId, address tokenIn, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        payable
        returns (uint256 amountOut);
}

interface IClCommunityAuctionViewFacet {
    function getClAuction(uint256 auctionId) external view returns (LibClAuctionStorage.ClCommunityAuction memory);
    function getClPosition(uint256 clPositionId) external view returns (LibClAuctionStorage.ClPosition memory);
    function getClTick(uint256 auctionId, int24 tick) external view returns (LibClAuctionStorage.TickInfo memory);
    function getClPoolState(uint256 auctionId) external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity);
    function getClFeeGrowthGlobals(uint256 auctionId) external view returns (uint256 feeGrowth0, uint256 feeGrowth1);
    function getClUnclaimedFees(uint256 clPositionId) external view returns (uint256 amount0, uint256 amount1);
    function getClEncumbranceLock(uint256 clPositionId) external view returns (uint256 lockedA, uint256 lockedB);
}

interface IClCommunityAuctionAdminFacet {
    function setClCreationEnabled(bool enabled) external;
    function setClSwapFeeCap(uint24 maxFeePips) external;
    function setClTickSpacingAllowed(uint24 tickSpacing, bool allowed) external;
    function setClSwapPaused(bool paused) external;
}

interface IClTestHarness {
    function setPositionNftRaw(address nft, bool enabled) external;
    function setAgentConfig(address registry, address implementation, bytes32 salt) external;
    function setClConfigRaw(address manager, bool creationEnabled, bool swapPaused, uint256 swapFeeCap) external;
    function setTimelock(address timelock) external;
    function setTreasury(address treasury) external;
    function setGlobalFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external;

    function seedPool(uint256 poolId, address token, bytes32 positionKey, uint256 principal, uint256 tracked) external;

    function getUserYield(uint256 poolId, bytes32 positionKey) external view returns (uint256);
    function getPoolYieldReserve(uint256 poolId) external view returns (uint256);
    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256);
    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256);
    function getModuleEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256);
    function getTbaDeployed(uint256 positionId) external view returns (bool);
}

contract ClMockTBAAccount {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract ClMock6551Registry is IERC6551Registry {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        returns (address accountAddress)
    {
        bytes32 deploySalt = _deploySalt(implementation, salt, chainId, tokenContract, tokenId);
        accountAddress = account(implementation, salt, chainId, tokenContract, tokenId);
        if (accountAddress.code.length == 0) {
            accountAddress = address(new ClMockTBAAccount{salt: deploySalt}());
        }
    }

    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        public
        view
        returns (address accountAddress)
    {
        bytes32 deploySalt = _deploySalt(implementation, salt, chainId, tokenContract, tokenId);
        accountAddress = Create2.computeAddress(deploySalt, keccak256(type(ClMockTBAAccount).creationCode), address(this));
    }

    function _deploySalt(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
    }
}

contract ClTestHarnessFacet {
    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setAgentConfig(address registry, address implementation, bytes32 salt) external {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        ds.erc6551Registry = registry;
        ds.erc6551Implementation = implementation;
        ds.tbaSalt = salt;
    }

    function setClConfigRaw(address manager, bool creationEnabled, bool swapPaused, uint256 swapFeeCap) external {
        if (swapFeeCap > type(uint24).max) revert();
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        cs.clPositionManager = manager;
        cs.creationEnabled = creationEnabled;
        cs.swapPaused = swapPaused;
        cs.swapFeeCap = uint24(swapFeeCap);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setGlobalFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        app.treasuryShareConfigured = true;
        app.treasuryShareBps = uint16(treasuryBps);
        app.activeCreditShareConfigured = true;
        app.activeCreditShareBps = uint16(activeCreditBps);
    }

    function seedPool(uint256 poolId, address token, bytes32 positionKey, uint256 principal, uint256 tracked) external {
        Types.PoolData storage p = LibAppStorage.s().pools[poolId];
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

    function getUserYield(uint256 poolId, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].userAccruedYield[positionKey];
    }

    function getPoolYieldReserve(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].yieldReserve;
    }

    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }

    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }

    function getModuleEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256)
    {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function getTbaDeployed(uint256 positionId) external view returns (bool) {
        return LibPositionAgentStorage.s().tbaDeployed[positionId];
    }
}

abstract contract ClTestBase is Test {
    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;

    uint256 internal constant CL_COMMUNITY_AUCTION_MODULE_ID =
        uint256(keccak256("equalis.cl.community.auction.module.v1"));

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RANDO = address(0xBAD);
    address internal constant TRADER = address(0xCAFE);

    Diamond internal diamond;

    IClCommunityAuctionFacet internal cl;
    IClCommunityAuctionViewFacet internal clView;
    IClCommunityAuctionAdminFacet internal clAdmin;
    IClTestHarness internal clHarness;

    PositionNFT internal positionNft;
    ClPositionManager internal clPositionManager;
    ClMock6551Registry internal registry;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal sourcePositionId;
    bytes32 internal sourcePositionKey;

    function setUpBase() internal {
        _deployDiamondAndFacets();
        _wireInterfaces();
        _deployMocks();
        _configureBaseState();
    }

    function _deployDiamondAndFacets() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        ClCommunityAuctionFacet clFacet = new ClCommunityAuctionFacet();
        ClCommunityAuctionViewFacet clViewFacet = new ClCommunityAuctionViewFacet();
        ClCommunityAuctionAdminFacet clAdminFacet = new ClCommunityAuctionAdminFacet();
        ClTestHarnessFacet harnessFacet = new ClTestHarnessFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(clFacet), _selectorsCl());
        cuts[2] = _cut(address(clViewFacet), _selectorsClView());
        cuts[3] = _cut(address(clAdminFacet), _selectorsClAdmin());
        cuts[4] = _cut(address(harnessFacet), _selectorsHarness());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));
    }

    function _wireInterfaces() internal {
        cl = IClCommunityAuctionFacet(address(diamond));
        clView = IClCommunityAuctionViewFacet(address(diamond));
        clAdmin = IClCommunityAuctionAdminFacet(address(diamond));
        clHarness = IClTestHarness(address(diamond));
    }

    function _deployMocks() internal {
        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));

        registry = new ClMock6551Registry();
        clPositionManager = new ClPositionManager(address(diamond));

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);
    }

    function _configureBaseState() internal {
        clHarness.setPositionNftRaw(address(positionNft), true);
        clHarness.setAgentConfig(address(registry), address(0xBEEF), keccak256("CL_TBA_SALT"));
        clHarness.setClConfigRaw(address(clPositionManager), true, false, 100_000);
        clAdmin.setClTickSpacingAllowed(60, true);

        sourcePositionId = positionNft.mint(ALICE, POOL_A);
        sourcePositionKey = positionNft.getPositionKey(sourcePositionId);

        clHarness.seedPool(POOL_A, address(tokenA), sourcePositionKey, 2_000_000e18, 2_000_000e18);
        clHarness.seedPool(POOL_B, address(tokenB), sourcePositionKey, 2_000_000e18, 2_000_000e18);

        tokenA.mint(address(diamond), 2_000_000e18);
        tokenB.mint(address(diamond), 2_000_000e18);
    }

    function _createAuction(uint64 startTime, uint64 endTime, uint256 poolIdA, uint256 poolIdB) internal returns (uint256 auctionId) {
        vm.prank(ALICE);
        auctionId = cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: poolIdA,
                poolIdB: poolIdB,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: startTime,
                endTime: endTime
            })
        );
    }

    function _createActiveAuction() internal returns (uint256 auctionId) {
        return _createAuction(uint64(block.timestamp), uint64(block.timestamp + 1 days), POOL_A, POOL_B);
    }

    function _createFutureAuction() internal returns (uint256 auctionId) {
        return _createAuction(uint64(block.timestamp + 1 hours), uint64(block.timestamp + 2 hours), POOL_A, POOL_B);
    }

    function _mintDefaultPosition(uint256 auctionId)
        internal
        returns (uint256 clPositionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        vm.prank(ALICE);
        return cl.mintClPosition(
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
    }

    function _expectedTbaAddress(uint256 positionId) internal view returns (address) {
        return registry.account(address(0xBEEF), keccak256("CL_TBA_SALT"), block.chainid, address(positionNft), positionId);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsCl() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = IClCommunityAuctionFacet.createClCommunityAuction.selector;
        s[1] = IClCommunityAuctionFacet.cancelClCommunityAuction.selector;
        s[2] = IClCommunityAuctionFacet.finalizeClCommunityAuction.selector;
        s[3] = IClCommunityAuctionFacet.mintClPosition.selector;
        s[4] = IClCommunityAuctionFacet.increaseClLiquidity.selector;
        s[5] = IClCommunityAuctionFacet.decreaseClLiquidity.selector;
        s[6] = IClCommunityAuctionFacet.collectClFees.selector;
        s[7] = IClCommunityAuctionFacet.burnClPosition.selector;
        s[8] = IClCommunityAuctionFacet.swapExactIn.selector;
    }

    function _selectorsClView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = IClCommunityAuctionViewFacet.getClAuction.selector;
        s[1] = IClCommunityAuctionViewFacet.getClPosition.selector;
        s[2] = IClCommunityAuctionViewFacet.getClTick.selector;
        s[3] = IClCommunityAuctionViewFacet.getClPoolState.selector;
        s[4] = IClCommunityAuctionViewFacet.getClFeeGrowthGlobals.selector;
        s[5] = IClCommunityAuctionViewFacet.getClUnclaimedFees.selector;
        s[6] = IClCommunityAuctionViewFacet.getClEncumbranceLock.selector;
    }

    function _selectorsClAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = IClCommunityAuctionAdminFacet.setClCreationEnabled.selector;
        s[1] = IClCommunityAuctionAdminFacet.setClSwapFeeCap.selector;
        s[2] = IClCommunityAuctionAdminFacet.setClTickSpacingAllowed.selector;
        s[3] = IClCommunityAuctionAdminFacet.setClSwapPaused.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = IClTestHarness.setPositionNftRaw.selector;
        s[1] = IClTestHarness.setAgentConfig.selector;
        s[2] = IClTestHarness.setClConfigRaw.selector;
        s[3] = IClTestHarness.setTimelock.selector;
        s[4] = IClTestHarness.setTreasury.selector;
        s[5] = IClTestHarness.setGlobalFeeSplits.selector;
        s[6] = IClTestHarness.seedPool.selector;
        s[7] = IClTestHarness.getUserYield.selector;
        s[8] = IClTestHarness.getPoolYieldReserve.selector;
        s[9] = IClTestHarness.getPoolTrackedBalance.selector;
        s[10] = IClTestHarness.getModuleEncumbered.selector;
        s[11] = IClTestHarness.getModuleEncumberedForModule.selector;
        s[12] = IClTestHarness.getTbaDeployed.selector;
    }
}
