// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexActionsFacetV3} from "../../src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexBaseV3, IEqualIndexFlashReceiver} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract EqualIndexActionsHarness is EqualIndexActionsFacetV3 {
    function initIndex(
        uint256 indexId,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16[] memory mintFeeBps,
        uint16[] memory burnFeeBps,
        uint16 flashFeeBps,
        address token
    ) external {
        Index storage idx = s().indexes[indexId];
        idx.assets = assets;
        idx.bundleAmounts = bundleAmounts;
        idx.mintFeeBps = mintFeeBps;
        idx.burnFeeBps = burnFeeBps;
        idx.flashFeeBps = flashFeeBps;
        idx.token = token;
        // manually set active state if needed, though default bool is false (not paused)
        
        // Update global count
        if (s().indexCount <= indexId) {
            s().indexCount = indexId + 1;
        }
    }

    function setPaused(uint256 indexId, bool paused) external {
        s().indexes[indexId].paused = paused;
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getFeePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function getTreasurySplitBps() external view returns (uint16) {
        return LibAppStorage.treasurySplitBps(LibAppStorage.s());
    }

    function getActiveCreditSplitBps() external view returns (uint16) {
        return LibAppStorage.activeCreditSplitBps(LibAppStorage.s());
    }

    function getTreasuryAddress() external view returns (address) {
        return LibAppStorage.treasuryAddress(LibAppStorage.s());
    }

    function setAssetPool(address asset, uint256 pid, uint256 totalDeposits) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits + totalDeposits;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setPoolTrackedBalance(uint256 pid, uint256 trackedBalance) external {
        LibAppStorage.s().pools[pid].trackedBalance = trackedBalance;
    }

    function getPoolYieldReserve(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }
}

contract FlashLoanReceiver is IEqualIndexFlashReceiver {
    bool public shouldFail;
    bool public shouldUnderpay;
    
    function setShouldFail(bool fail) external {
        shouldFail = fail;
    }
    
    function setShouldUnderpay(bool underpay) external {
        shouldUnderpay = underpay;
    }

    function onEqualIndexFlashLoan(
        uint256, /* indexId */
        uint256, /* units */
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata /* data */
    ) external override {
        if (shouldFail) {
            revert("FlashLoanReceiver: failed");
        }

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 repayAmount = amounts[i] + feeAmounts[i];
            if (shouldUnderpay && i == 0) {
                repayAmount -= 1;
            }
            IERC20(assets[i]).transfer(msg.sender, repayAmount);
        }
    }
}

contract EqualIndexActionsFacetV3Test is Test {
    EqualIndexActionsHarness internal facet;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    IndexToken internal indexToken;
    address internal treasury = address(0x999);
    
    uint256 internal constant INDEX_ID = 1;
    uint256 internal constant SCALE = 1e18;

    function setUp() public {
        facet = new EqualIndexActionsHarness();
        tokenA = new MockERC20("Token A", "TKA", 18, 0);
        tokenB = new MockERC20("Token B", "TKB", 18, 0);

        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 10 * SCALE; // 10 A per unit
        bundleAmounts[1] = 20 * SCALE; // 20 B per unit

        // Deploy IndexToken
        indexToken = new IndexToken(
            "Index Token",
            "IDX",
            address(facet),
            assets,
            bundleAmounts,
            0, // initial flash fee, will be overridden by storage
            INDEX_ID
        );

        uint16[] memory mintFees = new uint16[](2);
        mintFees[0] = 100; // 1%
        mintFees[1] = 100; // 1%

        uint16[] memory burnFees = new uint16[](2);
        burnFees[0] = 50; // 0.5%
        burnFees[1] = 50; // 0.5%

        facet.initIndex(
            INDEX_ID,
            assets,
            bundleAmounts,
            mintFees,
            burnFees,
            10, // 0.1% flash fee
            address(indexToken)
        );

        facet.setTreasury(treasury);
        facet.setAssetPool(address(tokenA), 1, 1_000_000 * SCALE);
        facet.setAssetPool(address(tokenB), 2, 1_000_000 * SCALE);

        // Mint tokens to this test contract
        tokenA.mint(address(this), 1_000_000 * SCALE);
        tokenB.mint(address(this), 1_000_000 * SCALE);

        tokenA.approve(address(facet), type(uint256).max);
        tokenB.approve(address(facet), type(uint256).max);
    }

    function _splitProtocol(uint256 amount) internal view returns (uint256 toTreasury, uint256 toActive, uint256 toIndex) {
        uint16 treasuryBps = facet.getTreasurySplitBps();
        uint16 activeBps = facet.getActiveCreditSplitBps();
        address treasuryAddr = facet.getTreasuryAddress();
        toTreasury = treasuryAddr != address(0) ? (amount * treasuryBps) / 10_000 : 0;
        toActive = (amount * activeBps) / 10_000;
        toIndex = amount - toTreasury - toActive;
    }

    function testMintBurn_MixedDecimalsBundle() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6, 0);
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8, 0);
        MockERC20 weth = new MockERC20("Wrapped ETH", "WETH", 18, 0);

        address[] memory assets = new address[](3);
        assets[0] = address(usdc);
        assets[1] = address(wbtc);
        assets[2] = address(weth);

        uint256[] memory bundleAmounts = new uint256[](3);
        bundleAmounts[0] = 1_000_000; // 1 USDC (6 decimals)
        bundleAmounts[1] = 5_000_000; // 0.05 WBTC (8 decimals)
        bundleAmounts[2] = 2 ether; // 2 WETH (18 decimals)

        uint16[] memory mintFees = new uint16[](3);
        uint16[] memory burnFees = new uint16[](3);

        uint256 indexId = INDEX_ID + 1;
        IndexToken mixedToken = new IndexToken(
            "Mixed Index",
            "MIX",
            address(facet),
            assets,
            bundleAmounts,
            0,
            indexId
        );

        facet.initIndex(indexId, assets, bundleAmounts, mintFees, burnFees, 0, address(mixedToken));

        facet.setAssetPool(address(usdc), 3, 1_000_000 * 1e6);
        facet.setAssetPool(address(wbtc), 4, 1_000 * 1e8);
        facet.setAssetPool(address(weth), 5, 1_000_000 ether);

        usdc.mint(address(this), 10_000_000);
        wbtc.mint(address(this), 100_000_000);
        weth.mint(address(this), 10 ether);

        usdc.approve(address(facet), type(uint256).max);
        wbtc.approve(address(facet), type(uint256).max);
        weth.approve(address(facet), type(uint256).max);

        uint256 units = 2 * SCALE;
        facet.mint(indexId, units, address(this));

        uint256 expectedUsdc = (bundleAmounts[0] * units) / SCALE;
        uint256 expectedWbtc = (bundleAmounts[1] * units) / SCALE;
        uint256 expectedWeth = (bundleAmounts[2] * units) / SCALE;

        assertEq(facet.getVaultBalance(indexId, address(usdc)), expectedUsdc, "usdc vault mismatch");
        assertEq(facet.getVaultBalance(indexId, address(wbtc)), expectedWbtc, "wbtc vault mismatch");
        assertEq(facet.getVaultBalance(indexId, address(weth)), expectedWeth, "weth vault mismatch");
        assertEq(mixedToken.totalSupply(), units, "index supply mismatch");

        uint256[] memory assetsOut = facet.burn(indexId, units, address(this));
        assertEq(assetsOut[0], expectedUsdc, "usdc burn mismatch");
        assertEq(assetsOut[1], expectedWbtc, "wbtc burn mismatch");
        assertEq(assetsOut[2], expectedWeth, "weth burn mismatch");

        assertEq(facet.getVaultBalance(indexId, address(usdc)), 0, "usdc vault not cleared");
        assertEq(facet.getVaultBalance(indexId, address(wbtc)), 0, "wbtc vault not cleared");
        assertEq(facet.getVaultBalance(indexId, address(weth)), 0, "weth vault not cleared");
        assertEq(mixedToken.totalSupply(), 0, "index supply not cleared");
    }

    function testMint() public {
        uint256 units = 5 * SCALE;
        
        uint256 balA_Before = tokenA.balanceOf(address(this));
        uint256 balB_Before = tokenB.balanceOf(address(this));

        facet.mint(INDEX_ID, units, address(this));

        assertEq(indexToken.balanceOf(address(this)), units);
        assertEq(indexToken.totalSupply(), units);

        // Check Vault Balances
        // Required for A: 5 * 10 = 50. Fee: 1% of 50 = 0.5. Total pulled: 50.5
        // Required for B: 5 * 20 = 100. Fee: 1% of 100 = 1. Total pulled: 101
        
        assertEq(facet.getVaultBalance(INDEX_ID, address(tokenA)), 50 * SCALE);
        assertEq(facet.getVaultBalance(INDEX_ID, address(tokenB)), 100 * SCALE);

        // Check user balance decrease
        assertEq(balA_Before - tokenA.balanceOf(address(this)), 505 * SCALE / 10);
        assertEq(balB_Before - tokenB.balanceOf(address(this)), 101 * SCALE);

        // Check Fees (40% pool share routed through fee router)
        uint256 feeA = 5 * SCALE / 10; // 0.5
        uint256 poolShare = (feeA * 4000) / 10_000;
        uint256 potFee = feeA - poolShare;
        (uint256 toTreasury,,) = _splitProtocol(poolShare);
        assertEq(tokenA.balanceOf(treasury), toTreasury);
        assertEq(facet.getFeePot(INDEX_ID, address(tokenA)), potFee);
    }

    function testMintUsesExtraBackingWhenPoolShort() public {
        uint256 units = 10_000 * SCALE;
        uint256 totalDeposits = 1_000_000 * SCALE;
        facet.setPoolTrackedBalance(1, totalDeposits - 1);

        uint256 yieldBefore = facet.getPoolYieldReserve(1);
        facet.mint(INDEX_ID, units, address(this));
        uint256 yieldAfter = facet.getPoolYieldReserve(1);

        uint256 requiredA = 10 * units;
        uint256 feeA = (requiredA * 100) / 10_000;
        uint256 poolShare = (feeA * 4000) / 10_000;
        (, uint256 toActive, uint256 toIndex) = _splitProtocol(poolShare);
        uint256 expectedIncrease = toActive + toIndex;

        assertEq(yieldAfter - yieldBefore, expectedIncrease);
    }

    function testMintInvalidUnits() public {
        vm.expectRevert(); // InvalidUnits
        facet.mint(INDEX_ID, 15 * SCALE / 10, address(this)); // must be multiple of 1e18? 
        // Logic says: units % LibEqualIndex.INDEX_SCALE != 0
        // If passed 1.5e18, 1.5e18 % 1e18 = 0.5e18 != 0. Correct.
    }

    function testMintPaused() public {
        facet.setPaused(INDEX_ID, true);
        vm.expectRevert(); // IndexPaused
        facet.mint(INDEX_ID, 1 * SCALE, address(this));
    }

    function testBurn() public {
        // First mint
        uint256 units = 2 * SCALE;
        facet.mint(INDEX_ID, units, address(this));

        // Now burn 1 unit
        uint256 burnUnits = 1 * SCALE;
        
        uint256 treasuryA_Before = tokenA.balanceOf(treasury);
        uint256 potBalanceBefore = facet.getFeePot(INDEX_ID, address(tokenA));
        
        facet.burn(INDEX_ID, burnUnits, address(this));

        assertEq(indexToken.balanceOf(address(this)), 1 * SCALE);
        
        // Vault should decrease by NAV share (1 unit worth)
        // A: 10. B: 20.
        assertEq(facet.getVaultBalance(INDEX_ID, address(tokenA)), 10 * SCALE); // Started with 20
        assertEq(facet.getVaultBalance(INDEX_ID, address(tokenB)), 20 * SCALE); // Started with 40

        // User receives NAV share + Pot share - Burn Fee
        // Pot share A: 0.8 / 2 = 0.4 (total pot was 0.8 from minting 2 units)
        // Gross A: 10 (NAV) + 0.4 (Pot) = 10.4
        // Burn Fee A: 0.5% of 10.4 = 0.052
        // Payout A: 10.4 - 0.052 = 10.348
        
        // Check Treasury (burn fee pool share routed via fee router)
        uint256 potShare = Math.mulDiv(potBalanceBefore, burnUnits, units);
        uint256 gross = 10 * SCALE + potShare;
        uint256 burnFee = Math.mulDiv(gross, 50, 10_000);
        uint256 poolShare = (burnFee * 4000) / 10_000;
        (uint256 toTreasury,,) = _splitProtocol(poolShare);
        assertEq(tokenA.balanceOf(treasury) - treasuryA_Before, toTreasury);
    }

    function testFlashLoan() public {
        // Mint to provide liquidity
        facet.mint(INDEX_ID, 10 * SCALE, address(this));

        FlashLoanReceiver receiver = new FlashLoanReceiver();
        tokenA.mint(address(receiver), 10 * SCALE); // Provide extra for fees
        tokenB.mint(address(receiver), 10 * SCALE);

        uint256 loanUnits = 1 * SCALE;
        // Loan amounts: A=10, B=20.
        // Fee 0.1%: A=0.01, B=0.02.
        
        facet.flashLoan(INDEX_ID, loanUnits, address(receiver), "");

        // Verify fees collected in pot
        uint256 mintFeeA = 1 * SCALE; // 1% of 100
        uint256 mintPoolShare = (mintFeeA * 4000) / 10_000;
        uint256 mintPotShare = mintFeeA - mintPoolShare;

        uint256 flashFeeA = 1 * SCALE / 100; // 0.01
        uint256 flashPoolShare = (flashFeeA * 1000) / 10_000;
        uint256 flashPotShare = flashFeeA - flashPoolShare;

        assertEq(facet.getFeePot(INDEX_ID, address(tokenA)), mintPotShare + flashPotShare);
    }

    function testFlashLoanUnderpaid() public {
        facet.mint(INDEX_ID, 10 * SCALE, address(this));
        FlashLoanReceiver receiver = new FlashLoanReceiver();
        tokenA.mint(address(receiver), 10 * SCALE);
        tokenB.mint(address(receiver), 10 * SCALE);
        receiver.setShouldUnderpay(true);

        vm.expectRevert(); // FlashLoanUnderpaid
        facet.flashLoan(INDEX_ID, 1 * SCALE, address(receiver), "");
    }
    
    function testFlashLoanReceiverRevert() public {
        facet.mint(INDEX_ID, 10 * SCALE, address(this));
        FlashLoanReceiver receiver = new FlashLoanReceiver();
        receiver.setShouldFail(true);
        
        vm.expectRevert("FlashLoanReceiver: failed");
        facet.flashLoan(INDEX_ID, 1 * SCALE, address(receiver), "");
    }
}
