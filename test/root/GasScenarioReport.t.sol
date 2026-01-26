// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexFacetV3} from "../../src/equalindex/EqualIndexFacetV3.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {PoolManagementFacet} from "../../src/equallend/PoolManagementFacet.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {PenaltyFacet} from "../../src/equallend/PenaltyFacet.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "../equallend-direct/DirectDiamondTestBase.sol";

contract EqualIndexFacetHarness is EqualIndexFacetV3 {
    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setAssetPool(address asset, uint256 pid, uint256 totalDeposits) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = asset;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setDefaultPoolConfig() external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.defaultPoolConfigSet = true;
        Types.PoolConfig storage cfg = store.defaultPoolConfig;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 9;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 500;
    }
}

contract IndexFlashBorrower {
    function onEqualIndexFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external {
        for (uint256 i = 0; i < assets.length; i++) {
            IERC20(assets[i]).transfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
    }
}

contract PoolAdminHarness is PoolManagementFacet, AdminGovernanceFacet {}

contract PositionManagementHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying, uint256 minDeposit, uint256 minLoan, uint16 ltvBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        LibPoolMembership._ensurePoolMembership(bytes32(0), pid, true);
    }

    function setAccruedYield(uint256 pid, bytes32 positionKey, uint256 yieldAmount) external {
        Types.PoolData storage p = s().pools[pid];
        p.userAccruedYield[positionKey] = yieldAmount;
        p.trackedBalance += yieldAmount;
        p.yieldReserve += yieldAmount;
        MockERC20(p.underlying).mint(address(this), yieldAmount);
    }
}

contract LendingHarness is LendingFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function addFixedTermConfig(uint256 pid, uint40 duration, uint16 apyBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.poolConfig.fixedTermConfigs.push(Types.FixedTermConfig({durationSecs: duration, apyBps: apyBps}));
    }

    function initPool(uint256 pid, address underlying, uint16 ltvBps, uint16 rollingApyBps) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.poolConfig.minTopupAmount = 1;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.poolConfig.rollingApyBps = rollingApyBps;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal, uint256 trackedBalance) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits += principal;
        p.trackedBalance = trackedBalance;
        p.userFeeIndex[positionKey] = LibFeeIndex.INDEX_SCALE;
        p.userMaintenanceIndex[positionKey] = LibFeeIndex.INDEX_SCALE;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
    }
}

contract PenaltyHarness is PenaltyFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        s().rollingDelinquencyEpochs = 2;
        s().rollingPenaltyEpochs = 3;
    }

    function seedPosition(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal * 4;
        p.userFeeIndex[positionKey] = LibFeeIndex.INDEX_SCALE;
        p.userMaintenanceIndex[positionKey] = LibFeeIndex.INDEX_SCALE;
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);
    }

    function seedRollingLoan(uint256 pid, bytes32 positionKey, uint256 principal, uint8 missedPayments) external {
        Types.RollingCreditLoan storage loan = s().pools[pid].rollingLoans[positionKey];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.openedAt = uint40(block.timestamp);
        loan.lastPaymentTimestamp = uint40(block.timestamp);
        loan.lastAccrualTs = uint40(block.timestamp);
        loan.apyBps = 1000;
        loan.missedPayments = missedPayments;
        loan.paymentIntervalSecs = 1 days;
        loan.depositBacked = true;
        loan.active = true;
        loan.principalAtOpen = s().pools[pid].userPrincipal[positionKey];
    }

    function seedFixedLoan(uint256 pid, bytes32 positionKey, uint256 loanId, uint256 principal, uint40 expiry) external {
        Types.PoolData storage p = s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.principal = principal;
        loan.principalRemaining = principal;
        loan.openedAt = uint40(block.timestamp);
        loan.expiry = expiry;
        loan.borrower = positionKey;
        loan.closed = false;
        loan.interestRealized = true;
        loan.principalAtOpen = p.userPrincipal[positionKey];
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = 0;
        p.activeFixedLoanCount[positionKey] = 1;
        p.fixedTermPrincipalRemaining[positionKey] = principal;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }
}

contract GasScenarioReportTest is DirectDiamondTestBase {
    address internal user = address(0xA11CE);
    address internal lender = address(0xBEEF);
    address internal treasury = address(0x9999);

    uint256 internal constant INDEX_SCALE = 1e18;

    function test_gas_IndexCreateWithFee() public {
        vm.pauseGasMetering();
        EqualIndexFacetHarness facet = new EqualIndexFacetHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        facet.setTreasury(treasury);
        _setIndexCreationFee(address(facet), 0.1 ether);
        vm.deal(address(this), 0.1 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 100;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 100;

        facet.setAssetPool(address(token), 1, 1_000_000 ether);
        facet.setDefaultPoolConfig();

        vm.resumeGasMetering();
        facet.createIndex{value: 0.1 ether}(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 50
            })
        );
    }

    function test_gas_IndexMintBurnFlow() public {
        (EqualIndexFacetHarness facet, MockERC20 token, uint256 indexId) = _createIndexWithFee();
        IndexToken idxToken = IndexToken(facet.getIndex(indexId).token);

        uint256 units = INDEX_SCALE;
        uint256 required = 1 ether;
        uint256 fee = (required * 100) / 10_000;

        token.approve(address(facet), required + fee);
        facet.mint(indexId, units, address(this));

        idxToken.approve(address(facet), idxToken.balanceOf(address(this)));
        facet.burn(indexId, units, address(this));
    }

    function test_gas_IndexMintOnly() public {
        vm.pauseGasMetering();
        (EqualIndexFacetHarness facet, MockERC20 token, uint256 indexId) = _createIndexWithFee();

        uint256 units = INDEX_SCALE;
        uint256 required = 1 ether;
        uint256 fee = (required * 100) / 10_000;

        token.approve(address(facet), required + fee);
        vm.resumeGasMetering();
        facet.mint(indexId, units, address(this));
    }

    function test_gas_IndexBurnOnly() public {
        vm.pauseGasMetering();
        (EqualIndexFacetHarness facet, MockERC20 token, uint256 indexId) = _createIndexWithFee();
        IndexToken idxToken = IndexToken(facet.getIndex(indexId).token);

        uint256 units = INDEX_SCALE;
        uint256 required = 1 ether;
        uint256 fee = (required * 100) / 10_000;

        token.approve(address(facet), required + fee);
        facet.mint(indexId, units, address(this));

        idxToken.approve(address(facet), idxToken.balanceOf(address(this)));
        vm.resumeGasMetering();
        facet.burn(indexId, units, address(this));
    }

    function test_gas_IndexFlashLoanFeeSplit() public {
        vm.pauseGasMetering();
        (EqualIndexFacetHarness facet, MockERC20 token, uint256 indexId) = _createIndexWithFee();
        IndexToken idxToken = IndexToken(facet.getIndex(indexId).token);

        uint256 units = INDEX_SCALE;
        uint256 required = 1 ether;
        uint256 fee = (required * 100) / 10_000;

        token.approve(address(facet), required + fee);
        facet.mint(indexId, units, address(this));

        IndexFlashBorrower borrower = new IndexFlashBorrower();
        token.mint(address(borrower), 10 ether);
        vm.resumeGasMetering();
        facet.flashLoan(indexId, units, address(borrower), "");

        vm.pauseGasMetering();
        idxToken.approve(address(facet), idxToken.balanceOf(address(this)));
        facet.burn(indexId, units, address(this));
    }

    function test_gas_PoolInitMinimal() public {
        vm.pauseGasMetering();
        PoolAdminHarness pool = new PoolAdminHarness();
        _setContractOwner(address(pool), address(this));
        _setTreasury(address(pool), treasury);

        Types.PoolConfig memory config;
        config.minDepositAmount = 1;
        config.minLoanAmount = 1;
        config.depositorLTVBps = 8000;
        config.aumFeeMinBps = 0;
        config.aumFeeMaxBps = 500;

        vm.resumeGasMetering();
        pool.initPool(1, address(new MockERC20("PoolToken", "P", 18, 1 ether)), config);
    }

    function test_gas_PositionDepositWithdrawCloseCleanup() public {
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness pm = new PositionManagementHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(pm));
        pm.initPool(1, address(token), 1, 1, 8000);

        token.transfer(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(pm), type(uint256).max);
        uint256 tokenId = pm.mintPosition(1);
        pm.depositToPosition(tokenId, 1, 100 ether);
        pm.withdrawFromPosition(tokenId, 1, 40 ether);
        pm.withdrawFromPosition(tokenId, 1, 60 ether);
        pm.cleanupMembership(tokenId, 1);
        vm.stopPrank();
    }

    function test_gas_PositionDepositOnly() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness pm = new PositionManagementHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(pm));
        pm.initPool(1, address(token), 1, 1, 8000);

        token.transfer(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(pm), type(uint256).max);
        uint256 tokenId = pm.mintPosition(1);
        vm.resumeGasMetering();
        pm.depositToPosition(tokenId, 1, 100 ether);
        vm.stopPrank();
    }

    function test_gas_PositionWithdrawOnly() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness pm = new PositionManagementHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(pm));
        pm.initPool(1, address(token), 1, 1, 8000);

        token.transfer(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(pm), type(uint256).max);
        uint256 tokenId = pm.mintPosition(1);
        pm.depositToPosition(tokenId, 1, 100 ether);
        vm.resumeGasMetering();
        pm.withdrawFromPosition(tokenId, 1, 100 ether);
        vm.stopPrank();
    }

    function test_gas_RollYieldToPosition() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness pm = new PositionManagementHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(pm));
        pm.initPool(1, address(token), 1, 1, 8000);

        token.transfer(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(pm), type(uint256).max);
        uint256 tokenId = pm.mintPosition(1);
        pm.depositToPosition(tokenId, 1, 100 ether);
        vm.stopPrank();

        bytes32 positionKey = nft.getPositionKey(tokenId);
        pm.setAccruedYield(1, positionKey, 3 ether);

        vm.startPrank(user);
        vm.resumeGasMetering();
        pm.rollYieldToPosition(tokenId, 1);
        vm.stopPrank();
    }

    function test_gas_PositionMintAndDeposit() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness pm = new PositionManagementHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(pm));
        pm.initPool(1, address(token), 1, 1, 8000);

        token.transfer(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(pm), type(uint256).max);
        vm.resumeGasMetering();
        uint256 tokenId = pm.mintPosition(1);
        pm.depositToPosition(tokenId, 1, 100 ether);
        vm.stopPrank();
    }

    function test_gas_PositionClosePoolPosition() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        PositionManagementHarness pm = new PositionManagementHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(pm));
        pm.initPool(1, address(token), 1, 1, 8000);

        token.transfer(user, 1_000 ether);
        vm.startPrank(user);
        token.approve(address(pm), type(uint256).max);
        uint256 tokenId = pm.mintPosition(1);
        pm.depositToPosition(tokenId, 1, 100 ether);
        vm.resumeGasMetering();
        pm.closePoolPosition(tokenId, 1);
        vm.stopPrank();
    }

    function test_gas_RollingLifecycle() public {
        PositionNFT nft = new PositionNFT();
        LendingHarness lending = new LendingHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        lending.configurePositionNFT(address(nft));
        nft.setMinter(address(lending));
        lending.initPool(1, address(token), 8000, 500);

        uint256 tokenId = _mintPosition(nft, address(lending), user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        lending.seedPosition(1, key, 100 ether, 1_000 ether);
        token.mint(address(lending), 1_000 ether);
        token.mint(user, 1_000 ether);

        vm.startPrank(user);
        token.approve(address(lending), type(uint256).max);
        lending.openRollingFromPosition(tokenId, 1, 20 ether);
        lending.makePaymentFromPosition(tokenId, 1, 1 ether);
        lending.closeRollingCreditFromPosition(tokenId, 1);
        vm.stopPrank();
    }

    function test_gas_BorrowRollingOnly() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        LendingHarness lending = new LendingHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        lending.configurePositionNFT(address(nft));
        nft.setMinter(address(lending));
        lending.initPool(1, address(token), 8000, 500);

        uint256 tokenId = _mintPosition(nft, address(lending), user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        lending.seedPosition(1, key, 100 ether, 1_000 ether);
        token.mint(address(lending), 1_000 ether);
        token.mint(user, 1_000 ether);

        vm.startPrank(user);
        token.approve(address(lending), type(uint256).max);
        vm.resumeGasMetering();
        lending.openRollingFromPosition(tokenId, 1, 20 ether);
        vm.stopPrank();
    }

    function test_gas_FixedLifecycle() public {
        PositionNFT nft = new PositionNFT();
        LendingHarness lending = new LendingHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        lending.configurePositionNFT(address(nft));
        nft.setMinter(address(lending));
        lending.initPool(1, address(token), 8000, 500);

        lending.addFixedTermConfig(1, 30 days, 200);

        uint256 tokenId = _mintPosition(nft, address(lending), user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        lending.seedPosition(1, key, 200 ether, 1_000 ether);
        token.mint(address(lending), 1_000 ether);
        token.mint(user, 1_000 ether);

        vm.startPrank(user);
        token.approve(address(lending), type(uint256).max);
        uint256 loanId = lending.openFixedFromPosition(tokenId, 1, 50 ether, 0);
        lending.repayFixedFromPosition(tokenId, 1, loanId, 50 ether);
        vm.stopPrank();
    }

    function test_gas_BorrowFixedOnly() public {
        vm.pauseGasMetering();
        PositionNFT nft = new PositionNFT();
        LendingHarness lending = new LendingHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        lending.configurePositionNFT(address(nft));
        nft.setMinter(address(lending));
        lending.initPool(1, address(token), 8000, 500);
        lending.addFixedTermConfig(1, 30 days, 200);

        uint256 tokenId = _mintPosition(nft, address(lending), user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        lending.seedPosition(1, key, 200 ether, 1_000 ether);
        token.mint(address(lending), 1_000 ether);
        token.mint(user, 1_000 ether);

        vm.startPrank(user);
        token.approve(address(lending), type(uint256).max);
        vm.resumeGasMetering();
        lending.openFixedFromPosition(tokenId, 1, 50 ether, 0);
        vm.stopPrank();
    }

    function test_gas_PenaltyRolling() public {
        PositionNFT nft = new PositionNFT();
        PenaltyHarness liq = new PenaltyHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        liq.configurePositionNFT(address(nft));
        nft.setMinter(address(liq));
        liq.initPool(1, address(token));
        liq.setTreasury(treasury);
        token.mint(address(liq), 1_000 ether);

        uint256 tokenId = _mintPosition(nft, address(liq), user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        liq.seedPosition(1, key, 100 ether);
        liq.seedRollingLoan(1, key, 50 ether, 5);

        liq.penalizePositionRolling(tokenId, 1, lender);
    }

    function test_gas_PenaltyFixed() public {
        PositionNFT nft = new PositionNFT();
        PenaltyHarness liq = new PenaltyHarness();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        liq.configurePositionNFT(address(nft));
        nft.setMinter(address(liq));
        liq.initPool(1, address(token));
        liq.setTreasury(treasury);
        token.mint(address(liq), 1_000 ether);

        uint256 tokenId = _mintPosition(nft, address(liq), user, 1);
        bytes32 key = nft.getPositionKey(tokenId);
        liq.seedPosition(1, key, 100 ether);
        liq.seedFixedLoan(1, key, 1, 50 ether, uint40(block.timestamp - 1));

        liq.penalizePositionFixed(tokenId, 1, 1, lender);
    }

    function test_gas_DirectOfferRepayFlow() public {
        setUpDiamond();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        harness.initPool(1, address(token), 1, 1, 8000);
        harness.initPool(2, address(token), 1, 1, 8000);
        _configureDirect(treasury);
        token.mint(address(diamond), 500 ether);
        token.mint(address(diamond), 500 ether);

        uint256 lenderTokenId = _mintPosition(nft, address(this), lender, 1);
        uint256 borrowerTokenId = _mintPosition(nft, address(this), user, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);

        harness.seedPosition(1, lenderKey, 200 ether, 200 ether);
        harness.seedPosition(2, borrowerKey, 150 ether, 150 ether);
        token.mint(lender, 200 ether);
        token.mint(user, 200 ether);
        vm.prank(lender);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 200,
            durationSeconds: 30 days,
            collateralLockAmount: 60 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.startPrank(lender);
        uint256 offerId = offers.postOffer(params);
        vm.stopPrank();

        vm.prank(user);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);

        vm.prank(user);
        lifecycle.repay(agreementId);
    }

    function test_gas_DirectPostOfferOnly() public {
        vm.pauseGasMetering();
        setUpDiamond();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        harness.initPool(1, address(token), 1, 1, 8000);
        harness.initPool(2, address(token), 1, 1, 8000);
        _configureDirect(treasury);
        token.mint(address(diamond), 500 ether);
        token.mint(address(diamond), 500 ether);

        uint256 lenderTokenId = _mintPosition(nft, address(this), lender, 1);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        harness.seedPosition(1, lenderKey, 200 ether, 200 ether);
        token.mint(lender, 200 ether);
        vm.prank(lender);
        token.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 200,
            durationSeconds: 30 days,
            collateralLockAmount: 60 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.startPrank(lender);
        vm.resumeGasMetering();
        offers.postOffer(params);
        vm.stopPrank();
    }

    function test_gas_DirectAcceptOfferOnly() public {
        vm.pauseGasMetering();
        setUpDiamond();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        harness.initPool(1, address(token), 1, 1, 8000);
        harness.initPool(2, address(token), 1, 1, 8000);
        _configureDirect(treasury);
        token.mint(address(diamond), 500 ether);

        uint256 lenderTokenId = _mintPosition(nft, address(this), lender, 1);
        uint256 borrowerTokenId = _mintPosition(nft, address(this), user, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);

        harness.seedPosition(1, lenderKey, 200 ether, 200 ether);
        harness.seedPosition(2, borrowerKey, 150 ether, 150 ether);
        token.mint(lender, 200 ether);
        token.mint(user, 200 ether);
        vm.prank(lender);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 200,
            durationSeconds: 30 days,
            collateralLockAmount: 60 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.startPrank(lender);
        uint256 offerId = offers.postOffer(params);
        vm.stopPrank();

        vm.prank(user);
        vm.resumeGasMetering();
        agreements.acceptOffer(offerId, borrowerTokenId);
    }

    function test_gas_DirectPostBorrowerOfferOnly() public {
        vm.pauseGasMetering();
        setUpDiamond();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        harness.initPool(1, address(token), 1, 1, 8000);
        harness.initPool(2, address(token), 1, 1, 8000);
        _configureDirect(treasury);

        uint256 borrowerTokenId = _mintPosition(nft, address(this), user, 2);
        finalizePositionNFT();
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);
        harness.seedPosition(2, borrowerKey, 200 ether, 200 ether);
        token.mint(user, 200 ether);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerTokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 200,
            durationSeconds: 30 days,
            collateralLockAmount: 60 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.startPrank(user);
        vm.resumeGasMetering();
        offers.postBorrowerOffer(params);
        vm.stopPrank();
    }

    function test_gas_DirectAcceptBorrowerOfferOnly() public {
        vm.pauseGasMetering();
        setUpDiamond();
        MockERC20 token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        harness.initPool(1, address(token), 1, 1, 8000);
        harness.initPool(2, address(token), 1, 1, 8000);
        _configureDirect(treasury);
        token.mint(address(diamond), 500 ether);

        uint256 lenderTokenId = _mintPosition(nft, address(this), lender, 1);
        uint256 borrowerTokenId = _mintPosition(nft, address(this), user, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);

        harness.seedPosition(1, lenderKey, 200 ether, 200 ether);
        harness.seedPosition(2, borrowerKey, 200 ether, 200 ether);
        token.mint(lender, 200 ether);
        token.mint(user, 200 ether);
        vm.prank(lender);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerTokenId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 200,
            durationSeconds: 30 days,
            collateralLockAmount: 60 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.startPrank(user);
        uint256 offerId = offers.postBorrowerOffer(params);
        vm.stopPrank();

        vm.prank(lender);
        vm.resumeGasMetering();
        agreements.acceptBorrowerOffer(offerId, lenderTokenId);
    }

    function _configureDirect(address protocolTreasury) internal {
        views.setDirectConfig(_directConfig());
        harness.setTreasuryShare(protocolTreasury, 4000);
        harness.setActiveCreditShare(0);
    }

    function _directConfig() internal pure returns (DirectTypes.DirectConfig memory) {
        return DirectTypes.DirectConfig({
            platformFeeBps: 100,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5_000,
            defaultLenderBps: 8_000,
            minInterestDuration: 0
        });
    }

    function _setTreasury(address target, address newTreasury) internal {
        bytes32 base = keccak256("equal.lend.app.storage");
        bytes32 treasurySlot = bytes32(uint256(base) + 4);
        uint256 value = uint256(uint160(newTreasury));
        vm.store(target, treasurySlot, bytes32(value));
    }

    function _setIndexCreationFee(address target, uint256 newFee) internal {
        bytes32 base = keccak256("equal.lend.app.storage");
        bytes32 feeSlot = bytes32(uint256(base) + 9);
        vm.store(target, feeSlot, bytes32(newFee));
    }

    function _setContractOwner(address target, address owner) internal {
        bytes32 base = keccak256("diamond.standard.diamond.storage");
        bytes32 ownerSlot = bytes32(uint256(base) + 3);
        vm.store(target, ownerSlot, bytes32(uint256(uint160(owner))));
    }

    function _mintPosition(PositionNFT nft, address minter, address owner, uint256 pid) internal returns (uint256) {
        vm.prank(minter);
        return nft.mint(owner, pid);
    }

    function _createIndexWithFee()
        internal
        returns (EqualIndexFacetHarness facet, MockERC20 token, uint256 indexId)
    {
        facet = new EqualIndexFacetHarness();
        token = new MockERC20("Token", "TOK", 18, 1_000_000 ether);

        facet.setTreasury(treasury);
        _setIndexCreationFee(address(facet), 0.1 ether);
        vm.deal(address(this), 1 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory bundle = new uint256[](1);
        bundle[0] = 1 ether;
        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 100;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 100;

        facet.setAssetPool(address(token), 1, 1_000_000 ether);
        facet.setDefaultPoolConfig();

        (indexId,) = facet.createIndex{value: 0.1 ether}(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 50
            })
        );
    }
}
