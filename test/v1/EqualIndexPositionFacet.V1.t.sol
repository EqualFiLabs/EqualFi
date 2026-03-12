// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualIndexAdminFacetV3} from "../../src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexBaseV3} from "../../src/equalindex/EqualIndexBaseV3.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";

contract LocalPositionMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualIndexPositionV1Harness is EqualIndexAdminFacetV3, EqualIndexPositionFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function pointsBalanceForKey(bytes32 pointsKey) external view returns (uint256) {
        return LibPoints.balanceOf(pointsKey);
    }

    function setDefaultPoolConfig() external {
        Types.PoolConfig storage cfg = LibAppStorage.s().defaultPoolConfig;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 10_000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
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
        LocalPositionMockERC20V1(underlying).mint(address(this), totalDeposits);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        if (principal > 0 && p.userCount == 0) {
            p.userCount = 1;
        }
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getVaultBalanceRaw(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getIndexPoolId(uint256 indexId) external view returns (uint256) {
        return s().indexToPoolId[indexId];
    }

    function getEncumbered(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibIndexEncumbrance.getEncumbered(positionKey, pid);
    }

    function getPoolPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

contract EqualIndexPositionFacetV1Test is Test {
    address internal constant OWNER = address(0x1111);
    address internal constant NON_OWNER = address(0x2222);

    EqualIndexPositionV1Harness internal harness;
    PositionNFT internal nft;
    LocalPositionMockERC20V1 internal assetA;
    LocalPositionMockERC20V1 internal assetB;

    function setUp() public {
        harness = new EqualIndexPositionV1Harness();
        harness.setOwner(address(this));
        harness.setDefaultPoolConfig();

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));

        assetA = new LocalPositionMockERC20V1("AssetA", "A", 18);
        assetB = new LocalPositionMockERC20V1("AssetB", "B", 18);

        harness.seedPool(1, address(assetA), 100_000 ether);
        harness.seedPool(2, address(assetB), 100_000 ether);
        harness.setAssetToPoolId(address(assetA), 1);
        harness.setAssetToPoolId(address(assetB), 2);
    }

    function test_mintAndBurnFromPosition_fullLifecycle() public {
        (uint256 indexId, uint256 positionId, bytes32 positionKey, uint256 indexPoolId, address token) = _createIndexAndPosition(OWNER);

        vm.prank(OWNER);
        harness.mintFromPosition(positionId, indexId, LibEqualIndex.INDEX_SCALE);

        assertEq(harness.getVaultBalanceRaw(indexId, address(assetA)), 1 ether);
        assertEq(harness.getVaultBalanceRaw(indexId, address(assetB)), 2 ether);
        assertEq(harness.getEncumbered(positionKey, 1), 1 ether);
        assertEq(harness.getEncumbered(positionKey, 2), 2 ether);
        assertEq(harness.getPoolPrincipal(indexPoolId, positionKey), LibEqualIndex.INDEX_SCALE);
        assertEq(IndexToken(token).totalSupply(), LibEqualIndex.INDEX_SCALE);

        vm.prank(OWNER);
        uint256[] memory assetsOut = harness.burnFromPosition(positionId, indexId, LibEqualIndex.INDEX_SCALE);
        assertEq(assetsOut.length, 2);
        assertEq(assetsOut[0], 1 ether);
        assertEq(assetsOut[1], 2 ether);
        assertEq(harness.getVaultBalanceRaw(indexId, address(assetA)), 0);
        assertEq(harness.getVaultBalanceRaw(indexId, address(assetB)), 0);
        assertEq(harness.getEncumbered(positionKey, 1), 0);
        assertEq(harness.getEncumbered(positionKey, 2), 0);
        assertEq(harness.getPoolPrincipal(indexPoolId, positionKey), 0);
        assertEq(IndexToken(token).totalSupply(), 0);
    }

    function test_mintFromPosition_revertsForNonOwner() public {
        (uint256 indexId, uint256 positionId,,,) = _createIndexAndPosition(OWNER);

        vm.prank(NON_OWNER);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, NON_OWNER, positionId));
        harness.mintFromPosition(positionId, indexId, LibEqualIndex.INDEX_SCALE);
    }

    function test_pointsAccrue_forMintAndBurnFromPosition() public {
        harness.setPointsPerAction(LibPoints.ACTION_INDEX_MINT_POSITION, 7);
        harness.setPointsPerAction(LibPoints.ACTION_INDEX_BURN_POSITION, 11);
        (uint256 indexId, uint256 positionId, bytes32 positionKey,,) = _createIndexAndPosition(OWNER);

        assertEq(harness.pointsBalanceForKey(positionKey), 0);
        vm.prank(OWNER);
        harness.mintFromPosition(positionId, indexId, LibEqualIndex.INDEX_SCALE);
        assertEq(harness.pointsBalanceForKey(positionKey), 7);

        vm.prank(OWNER);
        harness.burnFromPosition(positionId, indexId, LibEqualIndex.INDEX_SCALE);
        assertEq(harness.pointsBalanceForKey(positionKey), 18);
    }

    function _createIndexAndPosition(address positionOwner)
        internal
        returns (uint256 indexId, uint256 positionId, bytes32 positionKey, uint256 indexPoolId, address token)
    {
        positionId = nft.mint(positionOwner, 1);
        positionKey = nft.getPositionKey(positionId);
        harness.setUserPrincipal(1, positionKey, 10_000 ether);
        harness.setUserPrincipal(2, positionKey, 10_000 ether);
        harness.joinPool(positionKey, 1);
        harness.joinPool(positionKey, 2);

        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory bundle = new uint256[](2);
        bundle[0] = 1 ether;
        bundle[1] = 2 ether;
        uint16[] memory mintFees = new uint16[](2);
        uint16[] memory burnFees = new uint16[](2);

        (indexId, token) = harness.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 0
            })
        );
        indexPoolId = harness.getIndexPoolId(indexId);
    }
}
