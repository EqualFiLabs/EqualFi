// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";

import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {PositionAgentTBAFacet} from "../../src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentRegistryFacet} from "../../src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentConfigFacet} from "../../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionMSCAImpl} from "../../src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {IERC6551Executable} from "@agent-wallet-core/interfaces/IERC6551Executable.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";

interface IIdentityRegistry {
    function register() external returns (uint256 agentId);
}

interface IFiatToken {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

interface IWETH {
    function deposit() external payable;
}

interface INonfungiblePositionManager {
    // Aerodrome Slipstream (Base) mint signature differs from UniswapV3:
    // selector 0xb5007d1f = mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint160))
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface ICLFactory {
    function getPool(address token0, address token1, int24 tickSpacing) external view returns (address pool);
}

interface IUniswapV3Pool {
    function fee() external view returns (uint24);

    function tickSpacing() external view returns (int24 spacing);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol
        );
}

contract PositionAgentAerodromeHarnessFacet is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.poolConfig.rollingApyBps = 0;
        p.feeIndex = p.feeIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.feeIndex;
        p.maintenanceIndex = p.maintenanceIndex == 0 ? LibFeeIndex.INDEX_SCALE : p.maintenanceIndex;
        p.activeCreditIndex = p.activeCreditIndex == 0 ? LibActiveCreditIndex.INDEX_SCALE : p.activeCreditIndex;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }
}

interface IAerodromeHarness {
    function configurePositionNFT(address nft) external;
    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external;
    function mintPosition(uint256 pid, uint256 maxFee) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount, uint256 maxAmount) external;
}

contract PositionAgentAerodromeSlipstreamForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant ERC8004_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    address internal constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;
    address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    address internal constant ENTRYPOINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    uint256 internal constant USDC_POOL = 1;
    uint256 internal constant WETH_POOL = 2;
    uint16 internal constant LTV_BPS = 9500;

    Diamond internal diamond;
    IAerodromeHarness internal harness;
    LendingFacet internal lending;
    PositionAgentTBAFacet internal tbaFacet;
    PositionAgentRegistryFacet internal registryFacet;
    PositionAgentConfigFacet internal configFacet;

    PositionNFT internal nft;
    PositionMSCAImpl internal tbaImpl;

    address internal owner = address(0xA11CE);

    function setUp() public {
        string memory rpc = "https://mainnet.base.org";
        uint256 blockNumber = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        uint256 fork = blockNumber == 0 ? vm.createFork(rpc) : vm.createFork(rpc, blockNumber);
        vm.selectFork(fork);

        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();
        PositionAgentAerodromeHarnessFacet pmFacet = new PositionAgentAerodromeHarnessFacet();
        LendingFacet lendingFacet = new LendingFacet();
        PositionAgentTBAFacet tbaFacetImpl = new PositionAgentTBAFacet();
        PositionAgentRegistryFacet registryFacetImpl = new PositionAgentRegistryFacet();
        PositionAgentConfigFacet configFacetImpl = new PositionAgentConfigFacet();

        IDiamondCut.FacetCut[] memory baseCuts = new IDiamondCut.FacetCut[](3);
        baseCuts[0] = _cut(address(cut), _selectors(cut));
        baseCuts[1] = _cut(address(loupe), _selectors(loupe));
        baseCuts[2] = _cut(address(own), _selectors(own));
        diamond = new Diamond(baseCuts, Diamond.DiamondArgs({owner: owner}));

        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](5);
        addCuts[0] = _cut(address(pmFacet), _selectors(pmFacet));
        addCuts[1] = _cut(address(lendingFacet), _selectors(lendingFacet));
        addCuts[2] = _cut(address(tbaFacetImpl), _selectors(tbaFacetImpl));
        addCuts[3] = _cut(address(registryFacetImpl), _selectors(registryFacetImpl));
        addCuts[4] = _cut(address(configFacetImpl), _selectors(configFacetImpl));
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");

        harness = IAerodromeHarness(address(diamond));
        lending = LendingFacet(address(diamond));
        tbaFacet = PositionAgentTBAFacet(address(diamond));
        registryFacet = PositionAgentRegistryFacet(address(diamond));
        configFacet = PositionAgentConfigFacet(address(diamond));

        nft = new PositionNFT();
        tbaImpl = new PositionMSCAImpl(ENTRYPOINT);

        harness.configurePositionNFT(address(nft));
        nft.setMinter(address(diamond));
        nft.setDiamond(address(diamond));

        vm.startPrank(owner);
        configFacet.setERC6551Registry(ERC6551_REGISTRY);
        configFacet.setERC6551Implementation(address(tbaImpl));
        configFacet.setIdentityRegistry(ERC8004_IDENTITY);
        vm.stopPrank();

        harness.initPool(USDC_POOL, USDC, 1, 1, LTV_BPS);
        harness.initPool(WETH_POOL, WETH, 1, 1, LTV_BPS);
    }

    function testFork_PositionAgentBorrowAndSlipstream() public {
        uint256 usdcDeposit = 1_000e6;
        uint256 wethDeposit = 1 ether;
        uint256 borrowAmount = (usdcDeposit * 95) / 100;

        // mint USDC via masterMinter on fork
        address masterMinter = IFiatToken(USDC).masterMinter();
        vm.prank(masterMinter);
        require(IFiatToken(USDC).configureMinter(owner, usdcDeposit + borrowAmount), "configure minter failed");
        vm.prank(owner);
        require(IFiatToken(USDC).mint(owner, usdcDeposit + borrowAmount), "mint failed");

        // wrap ETH into WETH on fork
        vm.deal(owner, wethDeposit + 0.5 ether);
        vm.prank(owner);
        IWETH(WETH).deposit{value: wethDeposit + 0.5 ether}();

        vm.startPrank(owner);
        IERC20(USDC).approve(address(diamond), type(uint256).max);
        IERC20(WETH).approve(address(diamond), type(uint256).max);

        uint256 tokenId = harness.mintPosition(USDC_POOL, 0);
        harness.depositToPosition(tokenId, USDC_POOL, usdcDeposit, usdcDeposit);
        harness.depositToPosition(tokenId, WETH_POOL, wethDeposit, wethDeposit);

        address tba = tbaFacet.deployTBA(tokenId);

        bytes memory registerData = abi.encodeWithSelector(IIdentityRegistry.register.selector);
        bytes memory registerResult = IERC6551Executable(tba).execute(ERC8004_IDENTITY, 0, registerData, 0);
        uint256 agentId = abi.decode(registerResult, (uint256));
        assertEq(IERC721(ERC8004_IDENTITY).ownerOf(agentId), tba, "agent owner is tba");
        registryFacet.recordAgentRegistration(tokenId, agentId);

        lending.openRollingFromPosition(tokenId, USDC_POOL, borrowAmount, borrowAmount);

        IERC20(USDC).transfer(tba, borrowAmount);
        IERC20(WETH).transfer(tba, 0.25 ether);
        vm.stopPrank();

        _mintSlipstreamPosition(tba, borrowAmount, 0.25 ether);
    }

    function _mintSlipstreamPosition(address tba, uint256 usdcAmount, uint256 wethAmount) internal {
        INonfungiblePositionManager npm = INonfungiblePositionManager(SLIPSTREAM_NPM);
        address factory = npm.factory();
        if (factory == address(0)) factory = CL_FACTORY;

        (address token0, address token1, uint256 amount0, uint256 amount1) = _sortTokens(usdcAmount, wethAmount);
        address pool = _selectPool(factory, token0, token1);
        int24 spacing = IUniswapV3Pool(pool).tickSpacing();
        (, int24 tick,,,,) = IUniswapV3Pool(pool).slot0();
        (int24 tickLower, int24 tickUpper) = _tickRangeFromTick(tick, spacing);

        _tbaExecute(tba, token0, abi.encodeCall(IERC20.approve, (address(npm), amount0)));
        _tbaExecute(tba, token1, abi.encodeCall(IERC20.approve, (address(npm), amount1)));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: spacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: tba,
            deadline: block.timestamp + 1,
            sqrtPriceLimitX96: 0
        });

        bytes memory result = _tbaExecute(
            tba,
            address(npm),
            abi.encodeWithSelector(INonfungiblePositionManager.mint.selector, params)
        );
        (uint256 positionId,, uint256 used0, uint256 used1) = abi.decode(result, (uint256, uint128, uint256, uint256));

        assertGt(positionId, 0, "slipstream position minted");
        assertGt(used0 + used1, 0, "liquidity consumed");
    }

    function _sortTokens(uint256 usdcAmount, uint256 wethAmount)
        internal
        pure
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        if (USDC < WETH) {
            token0 = USDC;
            token1 = WETH;
            amount0 = usdcAmount;
            amount1 = wethAmount;
        } else {
            token0 = WETH;
            token1 = USDC;
            amount0 = wethAmount;
            amount1 = usdcAmount;
        }
    }

    function _selectPool(address factory, address token0, address token1)
        internal
        view
        returns (address pool)
    {
        int24[6] memory spacings = [int24(1), int24(10), int24(60), int24(100), int24(200), int24(1000)];
        for (uint256 i = 0; i < spacings.length; i++) {
            address candidate = ICLFactory(factory).getPool(token0, token1, spacings[i]);
            if (candidate != address(0)) {
                return candidate;
            }
        }
        revert("slipstream pool not found");
    }

    function _tickRangeFromTick(int24 tick, int24 spacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 base = _floorTick(tick, spacing);
        tickLower = base - spacing * 5;
        tickUpper = base + spacing * 5;
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _tbaExecute(address tba, address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(owner);
        return IERC6551Executable(tba).execute(target, 0, data, 0);
    }

    function _cut(address facet, bytes4[] memory selectors_) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors_;
    }

    function _selectors(DiamondCutFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectors(DiamondLoupeFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectors(OwnershipFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectors(PositionAgentAerodromeHarnessFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = PositionAgentAerodromeHarnessFacet.configurePositionNFT.selector;
        s[1] = PositionAgentAerodromeHarnessFacet.initPool.selector;
        s[2] = PositionManagementFacet.mintPosition.selector;
        s[3] = PositionManagementFacet.depositToPosition.selector;
    }

    function _selectors(LendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = LendingFacet.openRollingFromPosition.selector;
    }

    function _selectors(PositionAgentTBAFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = PositionAgentTBAFacet.computeTBAAddress.selector;
        s[1] = PositionAgentTBAFacet.deployTBA.selector;
        s[2] = PositionAgentTBAFacet.getERC6551Registry.selector;
    }

    function _selectors(PositionAgentRegistryFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PositionAgentRegistryFacet.recordAgentRegistration.selector;
        s[1] = PositionAgentRegistryFacet.getIdentityRegistry.selector;
    }

    function _selectors(PositionAgentConfigFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = PositionAgentConfigFacet.setERC6551Registry.selector;
        s[1] = PositionAgentConfigFacet.setERC6551Implementation.selector;
        s[2] = PositionAgentConfigFacet.setIdentityRegistry.selector;
    }
}
