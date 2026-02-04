// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPool} from "@aave-v3-origin/contracts/interfaces/IPool.sol";
import {LeanDeployScript} from "../../script/leanDeploy.s.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";

// Interfaces (Renamed to avoid conflicts)
interface ILocalPositionManagement {
    function mintPosition(uint256 pid) external payable returns (uint256 tokenId);
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external payable returns (uint256 tokenId);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external payable;
}

interface ILocalPoolManagement {
    function initPoolWithActionFees(
        uint256 poolId,
        address underlyingToken,
        Types.PoolConfig calldata config,
        Types.ActionFeeSet calldata fees
    ) external payable;
}

interface ILocalLendingFacet {
    function openRollingFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
}

contract AaveOriginForkTest is Test {
    // Arbitrum Mainnet RPC
    string internal constant ARBITRUM_MAINNET_RPC = "https://arb1.arbitrum.io/rpc";
    uint256 internal constant ARBITRUM_FORK_BLOCK = 0; // Latest

    // Addresses
    address internal constant AAVE_V3_POOL_ARB = 0x794a61358D6845594F94dc1DB02A252b5b4814aD; // Mainnet Pool
    address internal constant WETH_ARB = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // Arbitrum Mainnet WETH

    // Contracts
    IPool internal aavePool;
    ILocalPositionManagement internal equalfiPosition;
    ILocalPoolManagement internal equalfiPools;
    ILocalLendingFacet internal lendingFacet;
    ERC20 internal weth;
    LeanDeployScript.Deployment internal sys;

    // Accounts
    address internal user;
    uint256 internal positionId;
    uint256 internal REAL_WETH_POOL_ID = 10;

    function setUp() public {
        // 1. Fork Arbitrum Mainnet
        uint256 forkId = vm.createFork(ARBITRUM_MAINNET_RPC);
        vm.selectFork(forkId);

        // 2. Setup User & Assets
        user = address(0x1337);
        vm.deal(user, 100 ether);
        
        // Load Real WETH
        weth = ERC20(WETH_ARB);
        // Wrap ETH -> Real WETH for user
        vm.startPrank(user);
        (bool success,) = address(weth).call{value: 50 ether}("");
        require(success, "Wrap failed");
        vm.stopPrank();

        // 3. Deploy EqualFi on Fork
        LeanDeployScript script = new LeanDeployScript();
        sys = script.deployForTest(address(this), address(this), address(this));
        
        equalfiPosition = ILocalPositionManagement(sys.diamond);
        equalfiPools = ILocalPoolManagement(sys.diamond);
        lendingFacet = ILocalLendingFacet(sys.diamond);
        aavePool = IPool(AAVE_V3_POOL_ARB);

        // 4. Init Real WETH Pool in EqualFi
        _initRealWethPool();
    }

    function _initRealWethPool() internal {
        Types.PoolConfig memory config;
        config.rollingApyBps = 500;
        config.depositorLTVBps = 9500; // 95% LTV
        config.maintenanceRateBps = 100;
        config.flashLoanFeeBps = 9;
        config.flashLoanAntiSplit = true;
        config.minDepositAmount = 0.01 ether;
        config.minLoanAmount = 0.02 ether;
        config.minTopupAmount = 0.01 ether;
        config.maxUserCount = 0;
        config.aumFeeMaxBps = 500;

        Types.ActionFeeSet memory fees; 
        // Zero fees for test simplicity
        
        // Init Pool 6
        equalfiPools.initPoolWithActionFees{value: 0}(
            REAL_WETH_POOL_ID,
            address(weth),
            config,
            fees
        );
    }

    function testDepositEqualFiBorrow95LTVDepositAave() public {
        vm.startPrank(user);

        // 1. Deposit Real WETH into EqualFi (20 WETH)
        weth.approve(sys.diamond, type(uint256).max);
        uint256 depositAmount = 20 ether;
        
        positionId = equalfiPosition.mintPositionWithDeposit(REAL_WETH_POOL_ID, depositAmount);
        
        // 2. Real Borrow: 9.5 WETH (Same-Asset / Self-Secured)
        uint256 borrowAmount = 9.5 ether;
        
        // Call openRollingFromPosition
        lendingFacet.openRollingFromPosition(positionId, REAL_WETH_POOL_ID, borrowAmount);
        
        // 3. Deposit the Borrowed WETH to Aave
        weth.approve(address(aavePool), type(uint256).max);
        aavePool.supply(address(weth), borrowAmount, user, 0);

        // 4. Assertions
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor,
            uint256 lastUpdateTimestamp
        ) = aavePool.getUserAccountData(user);

        assertGt(totalCollateralETH, 0, "Aave Collateral should increase");
        
        vm.stopPrank();
    }
}
