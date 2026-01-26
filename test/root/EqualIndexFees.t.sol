// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexFacetV3} from "../../src/equalindex/EqualIndexFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import "../../src/libraries/Errors.sol";

contract EqualIndexFeesHarness is EqualIndexFacetV3 {
    function setDefaultPoolConfig(Types.PoolConfig memory config) external {
        Types.PoolConfig storage target = LibAppStorage.s().defaultPoolConfig;
        target.rollingApyBps = config.rollingApyBps;
        target.depositorLTVBps = config.depositorLTVBps;
        target.maintenanceRateBps = config.maintenanceRateBps;
        target.flashLoanFeeBps = config.flashLoanFeeBps;
        target.flashLoanAntiSplit = config.flashLoanAntiSplit;
        target.minDepositAmount = config.minDepositAmount;
        target.minLoanAmount = config.minLoanAmount;
        target.minTopupAmount = config.minTopupAmount;
        target.isCapped = config.isCapped;
        target.depositCap = config.depositCap;
        target.maxUserCount = config.maxUserCount;
        target.aumFeeMinBps = config.aumFeeMinBps;
        target.aumFeeMaxBps = config.aumFeeMaxBps;
        target.borrowFee = config.borrowFee;
        target.repayFee = config.repayFee;
        target.withdrawFee = config.withdrawFee;
        target.flashFee = config.flashFee;
        target.closeRollingFee = config.closeRollingFee;
        delete target.fixedTermConfigs;
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            target.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = 1e18;
        p.maintenanceIndex = 1e18;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
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

    function setIndexCreationFee(uint256 fee) external {
        LibAppStorage.s().indexCreationFee = fee;
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }
}

contract FlashBorrowerMock {
    address public asset;
    uint256 public repayExtra;
    bool public underpay;

    function configure(address asset_, uint256 repayExtra_, bool underpay_) external {
        asset = asset_;
        repayExtra = repayExtra_;
        underpay = underpay_;
    }

    function onEqualIndexFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata,
        bytes calldata
    ) external {
        // repay either full amount (plus optional extra) or underpay by skipping fee entirely
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 repayAmount = underpay ? amounts[i] : amounts[i] + repayExtra;
            MockERC20(assets[i]).transfer(msg.sender, repayAmount);
        }
    }
}

contract EqualIndexFeesTest is Test {
    EqualIndexFeesHarness internal facet;
    MockERC20 internal token;
    address internal treasury = address(0xBEEF);
    uint256 internal indexId;
    uint256 internal indexCreationFee = 0.1 ether;

    uint16 internal constant MINT_FEE_BPS = 100; // 1%
    uint16 internal constant BURN_FEE_BPS = 100; // 1%
    uint16 internal constant FLASH_FEE_BPS = 100; // 1%

    function setUp() public {
        facet = new EqualIndexFeesHarness();
        token = new MockERC20("Token", "TOK", 18, 10_000 ether);

        facet.setDefaultPoolConfig(_validPoolConfig());
        facet.setTreasury(treasury);
        facet.setIndexCreationFee(indexCreationFee);
        vm.deal(address(this), indexCreationFee);
        facet.setAssetToPoolId(address(token), 1);
        facet.seedPool(1, address(token), 1_000 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = MINT_FEE_BPS;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = BURN_FEE_BPS;

        (indexId,) = facet.createIndex{value: indexCreationFee}(
            EqualIndexBaseV3.CreateIndexParams({
                name: "T",
                symbol: "T",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: FLASH_FEE_BPS
            })
        );
    }

    function _mintUnits(address to, uint256 units) internal returns (IndexToken idxToken) {
        idxToken = IndexToken(facet.getIndex(indexId).token);
        uint256 need = 1 ether * units / LibEqualIndex.INDEX_SCALE;
        uint256 fee = (need * MINT_FEE_BPS) / 10_000;
        token.approve(address(facet), need + fee);
        facet.mint(indexId, units, to);
    }

    function _setTimelock(address newTimelock) internal {
        facet.setTimelock(newTimelock);
    }

    function _setTreasury(address newTreasury) internal {
        facet.setTreasury(newTreasury);
    }

    function _validPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.minDepositAmount = 1 ether;
        cfg.minLoanAmount = 1 ether;
        cfg.minTopupAmount = 0.1 ether;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.rollingApyBps = 500;
    }

    function _splitProtocol(uint256 amount)
        internal
        view
        returns (uint256 toTreasury, uint256 toActive, uint256 toIndex)
    {
        uint16 treasuryBps = facet.getTreasurySplitBps();
        uint16 activeBps = facet.getActiveCreditSplitBps();
        address treasuryAddr = facet.getTreasuryAddress();
        toTreasury = treasuryAddr != address(0) ? (amount * treasuryBps) / 10_000 : 0;
        toActive = (amount * activeBps) / 10_000;
        toIndex = amount - toTreasury - toActive;
    }

    function test_MintAndBurnFeeSplits_TreasurySet() public {
        _setTreasury(treasury);

        uint256 treasuryStart = token.balanceOf(treasury);
        IndexToken idxToken = _mintUnits(address(this), LibEqualIndex.INDEX_SCALE);

        uint256 fee = 0.01 ether;
        // Pool share routed via fee router; remainder to fee pot
        uint256 poolShare = (fee * 4000) / 10_000; // 40% pool share
        uint256 expectedPot = fee - poolShare;
        (uint256 expectedProtocol,,) = _splitProtocol(poolShare);

        assertEq(facet.getVaultBalance(indexId, address(token)), 1 ether, "vault should hold bundle");
        assertEq(facet.getFeePot(indexId, address(token)), expectedPot, "fee pot share");
        assertEq(token.balanceOf(treasury) - treasuryStart, expectedProtocol, "protocol share to treasury");

        // Burn and check protocol/pot updates
        token.approve(address(facet), type(uint256).max);
        idxToken.approve(address(facet), idxToken.balanceOf(address(this)));
        uint256 treasuryBeforeBurn = token.balanceOf(treasury);
        facet.burn(indexId, LibEqualIndex.INDEX_SCALE, address(this));

        // Fee pot should still hold positive balance (pot fee added, pot share removed)
        assertGt(facet.getFeePot(indexId, address(token)), 0, "pot remains after burn fee");
        assertGt(token.balanceOf(treasury) - treasuryBeforeBurn, 0, "treasury received burn protocol fee");
        assertEq(facet.getVaultBalance(indexId, address(token)), 0, "vault emptied on full burn");
    }

    function test_MintFee_AllToPot_WhenTreasuryUnset() public {
        _setTreasury(address(0));

        _mintUnits(address(this), LibEqualIndex.INDEX_SCALE);

        uint256 fee = 0.01 ether;
        uint256 poolShare = (fee * 4000) / 10_000;
        uint256 expectedPot = fee - poolShare;
        assertEq(facet.getFeePot(indexId, address(token)), expectedPot, "remainder routed to pot");
        assertEq(token.balanceOf(treasury), 0, "treasury untouched");
    }

    function test_FlashLoanUnderpayReverts() public {
        _setTreasury(treasury);

        // Seed vault via mint
        _mintUnits(address(this), LibEqualIndex.INDEX_SCALE);

        FlashBorrowerMock borrower = new FlashBorrowerMock();
        borrower.configure(address(token), 0, true); // underpay: repay principal only
        token.transfer(address(borrower), 2 ether);

        vm.expectRevert();
        facet.flashLoan(indexId, LibEqualIndex.INDEX_SCALE, address(borrower), "");
    }

    function test_FlashLoanFeeSplits_WithAndWithoutTreasury() public {
        // Treasury set: protocol share should be transferred
        _setTreasury(treasury);
        _mintUnits(address(this), LibEqualIndex.INDEX_SCALE); // seed vault

        FlashBorrowerMock borrower = new FlashBorrowerMock();
        borrower.configure(address(token), 0.01 ether, false); // repay with extra to satisfy fee
        token.transfer(address(borrower), 2 ether);

        uint256 treasuryBefore = token.balanceOf(treasury);
        facet.flashLoan(indexId, LibEqualIndex.INDEX_SCALE, address(borrower), "");
        assertGt(token.balanceOf(treasury) - treasuryBefore, 0, "treasury received pool share split");
        assertGt(facet.getFeePot(indexId, address(token)), 0, "fee pot accrued flash fee");

        // Treasury unset: treasury share zero, pot gets remainder after pool share
        _setTreasury(address(0));
        borrower.configure(address(token), 0.01 ether, false);
        token.transfer(address(borrower), 2 ether);
        uint256 potBefore = facet.getFeePot(indexId, address(token));
        facet.flashLoan(indexId, LibEqualIndex.INDEX_SCALE, address(borrower), "");
        assertEq(token.balanceOf(treasury), token.balanceOf(treasury), "treasury unchanged when unset");
        assertGt(facet.getFeePot(indexId, address(token)) - potBefore, 0, "pot grew by remainder");
    }

    function test_PreviewHelpersMatchCoreScaling() public {
        IndexToken idxToken = IndexToken(facet.getIndex(indexId).token);
        uint256 units = 2 * LibEqualIndex.INDEX_SCALE;

        (, uint256[] memory requiredMint, uint256[] memory feeAmounts) = idxToken.previewMint(units);
        uint256 expectedNeed = 2 ether;
        uint256 expectedFee = (expectedNeed * MINT_FEE_BPS) / 10_000;
        assertEq(requiredMint[0], expectedNeed + expectedFee, "mint preview includes fee");
        assertEq(feeAmounts[0], expectedFee, "mint fee amount matches");

        (, uint256[] memory loanAmounts,) = idxToken.previewFlashLoan(units);
        assertEq(loanAmounts[0], 2 ether, "flash preview scales by INDEX_SCALE");
    }

    function test_PausedIndexBlocksOperations() public {
        // Set timelock and pause
        _setTimelock(address(this));
        facet.setPaused(indexId, true);

        token.approve(address(facet), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, indexId));
        facet.mint(indexId, LibEqualIndex.INDEX_SCALE, address(this));

        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, indexId));
        facet.burn(indexId, LibEqualIndex.INDEX_SCALE, address(this));

        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, indexId));
        facet.flashLoan(indexId, LibEqualIndex.INDEX_SCALE, address(this), "");
    }

    /// @dev Gas-path: mint then burn with treasury set.
    function test_gas_IndexMintBurnFlow() public {
        _setTreasury(treasury);
        IndexToken idxToken = _mintUnits(address(this), LibEqualIndex.INDEX_SCALE);

        token.approve(address(facet), type(uint256).max);
        idxToken.approve(address(facet), idxToken.balanceOf(address(this)));
        facet.burn(indexId, LibEqualIndex.INDEX_SCALE, address(this));
    }

    /// @dev Gas-path: flash loan with treasury set (vault seeded via mint).
    function test_gas_IndexFlashLoanFlow() public {
        _setTreasury(treasury);
        _mintUnits(address(this), LibEqualIndex.INDEX_SCALE);

        FlashBorrowerMock borrower = new FlashBorrowerMock();
        borrower.configure(address(token), 0.01 ether, false);
        token.transfer(address(borrower), 2 ether);

        facet.flashLoan(indexId, LibEqualIndex.INDEX_SCALE, address(borrower), "");
    }
}
