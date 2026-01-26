// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexPositionIntegrationHarness is EqualIndexAdminFacetV3, EqualIndexPositionFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

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

    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setUser(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function accruePoolFee(uint256 pid, uint256 amount) external {
        LibAppStorage.s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, keccak256("TEST_FEE"));
    }

    function settle(uint256 pid, bytes32 positionKey) external {
        LibFeeIndex.settle(pid, positionKey);
    }

    function getAccruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getFeePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }

    function getIndexPoolId(uint256 indexId) external view returns (uint256) {
        return s().indexToPoolId[indexId];
    }

    function getEncumbered(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibIndexEncumbrance.getEncumbered(positionKey, pid);
    }

    function getUserPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

contract EqualIndexPositionIntegrationTest is Test {
    function test_fullLifecycle_integration() public {
        MockERC20 assetA = new MockERC20("AssetA", "A", 18, 0);
        MockERC20 assetB = new MockERC20("AssetB", "B", 18, 0);

        EqualIndexPositionIntegrationHarness facet = new EqualIndexPositionIntegrationHarness();
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_validPoolConfig());

        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        address owner = address(0xBEEF);
        uint256 tokenId = nft.mint(owner, 1);
        facet.setPositionNFT(address(nft));

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.seedPool(1, address(assetA), 10_000 ether);
        facet.seedPool(2, address(assetB), 10_000 ether);
        facet.setUser(1, positionKey, 5_000 ether);
        facet.setUser(2, positionKey, 5_000 ether);
        facet.joinPool(positionKey, 1);
        facet.joinPool(positionKey, 2);
        facet.setAssetToPoolId(address(assetA), 1);
        facet.setAssetToPoolId(address(assetB), 2);

        EqualIndexBaseV3.CreateIndexParams memory params = _paramsForAssets(address(assetA), address(assetB), 0, 0);
        (uint256 indexId, address token) = facet.createIndex(params);
        uint256 indexPoolId = facet.getIndexPoolId(indexId);
        assertGt(indexPoolId, 0);
        assertEq(facet.getUserPrincipal(indexPoolId, positionKey), 0);

        vm.prank(owner);
        facet.mintFromPosition(tokenId, indexId, LibEqualIndex.INDEX_SCALE);

        assertGt(facet.getVaultBalance(indexId, address(assetA)), 0);
        assertGt(facet.getVaultBalance(indexId, address(assetB)), 0);
        assertGt(facet.getUserPrincipal(indexPoolId, positionKey), 0);

        facet.accruePoolFee(1, 10 ether);
        facet.accruePoolFee(2, 5 ether);
        facet.settle(1, positionKey);
        facet.settle(2, positionKey);
        assertGt(facet.getAccruedYield(1, positionKey), 0);
        assertGt(facet.getAccruedYield(2, positionKey), 0);

        vm.prank(owner);
        facet.burnFromPosition(tokenId, indexId, LibEqualIndex.INDEX_SCALE);

        assertEq(facet.getVaultBalance(indexId, address(assetA)), 0);
        assertEq(facet.getVaultBalance(indexId, address(assetB)), 0);
        assertEq(facet.getEncumbered(positionKey, 1), 0);
        assertEq(facet.getEncumbered(positionKey, 2), 0);
        assertEq(facet.getUserPrincipal(indexPoolId, positionKey), 0);
    }

    function test_multiPositionProportionalBurn() public {
        MockERC20 asset = new MockERC20("Asset", "AST", 18, 0);

        EqualIndexPositionIntegrationHarness facet = new EqualIndexPositionIntegrationHarness();
        facet.setOwner(address(this));
        facet.setDefaultPoolConfig(_validPoolConfig());

        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        address ownerA = address(0xA11);
        address ownerB = address(0xB22);
        uint256 tokenIdA = nft.mint(ownerA, 1);
        uint256 tokenIdB = nft.mint(ownerB, 1);
        facet.setPositionNFT(address(nft));

        bytes32 keyA = nft.getPositionKey(tokenIdA);
        bytes32 keyB = nft.getPositionKey(tokenIdB);
        facet.seedPool(1, address(asset), 20_000 ether);
        facet.setUser(1, keyA, 5_000 ether);
        facet.setUser(1, keyB, 5_000 ether);
        facet.joinPool(keyA, 1);
        facet.joinPool(keyB, 1);
        facet.setAssetToPoolId(address(asset), 1);

        EqualIndexBaseV3.CreateIndexParams memory params = _paramsForAssets(address(asset), address(0), 100, 0);
        (uint256 indexId, address token) = facet.createIndex(params);
        uint256 indexPoolId = facet.getIndexPoolId(indexId);
        assertGt(indexPoolId, 0);
        assertEq(IndexToken(token).totalSupply(), 0);

        uint256 unitsA = 2 * LibEqualIndex.INDEX_SCALE;
        uint256 unitsB = 4 * LibEqualIndex.INDEX_SCALE;

        vm.prank(ownerA);
        facet.mintFromPosition(tokenIdA, indexId, unitsA);
        vm.prank(ownerB);
        facet.mintFromPosition(tokenIdB, indexId, unitsB);

        uint256 totalSupply = unitsA + unitsB;
        uint256 vaultBalance = facet.getVaultBalance(indexId, address(asset));
        uint256 potBalance = facet.getFeePot(indexId, address(asset));

        uint256 expectedNavShare = (vaultBalance * unitsA) / totalSupply;
        uint256 expectedPotShare = (potBalance * unitsA) / totalSupply;
        uint256 expectedPayout = expectedNavShare + expectedPotShare;

        vm.prank(ownerA);
        uint256[] memory assetsOut = facet.burnFromPosition(tokenIdA, indexId, unitsA);

        assertEq(assetsOut.length, 1);
        assertEq(assetsOut[0], expectedPayout);
    }

    function _paramsForAssets(address assetA, address assetB, uint16 mintFeeBps, uint16 burnFeeBps)
        internal
        pure
        returns (EqualIndexBaseV3.CreateIndexParams memory p)
    {
        uint256 assetCount = assetB == address(0) ? 1 : 2;
        address[] memory assets = new address[](assetCount);
        uint256[] memory bundle = new uint256[](assetCount);
        uint16[] memory mintFees = new uint16[](assetCount);
        uint16[] memory burnFees = new uint16[](assetCount);

        assets[0] = assetA;
        bundle[0] = 1 ether;
        mintFees[0] = mintFeeBps;
        burnFees[0] = burnFeeBps;

        if (assetCount == 2) {
            assets[1] = assetB;
            bundle[1] = 2 ether;
            mintFees[1] = mintFeeBps;
            burnFees[1] = burnFeeBps;
        }

        p = EqualIndexBaseV3.CreateIndexParams({
            name: "IDX",
            symbol: "IDX",
            assets: assets,
            bundleAmounts: bundle,
            mintFeeBps: mintFees,
            burnFeeBps: burnFees,
            flashFeeBps: 0
        });
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
}
