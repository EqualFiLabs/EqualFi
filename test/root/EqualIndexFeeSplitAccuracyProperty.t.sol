// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexFeeSplitAccuracyHarness is EqualIndexPositionFacet {
    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
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

    function setIndex(
        uint256 indexId,
        address token,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16 mintFeeBps,
        uint16 burnFeeBps
    ) external {
        EqualIndexStorage storage es = s();
        if (es.indexCount <= indexId) {
            es.indexCount = indexId + 1;
        }
        Index storage idx = es.indexes[indexId];
        idx.assets = assets;
        idx.bundleAmounts = bundleAmounts;
        idx.mintFeeBps = new uint16[](assets.length);
        idx.burnFeeBps = new uint16[](assets.length);
        idx.mintFeeBps[0] = mintFeeBps;
        idx.burnFeeBps[0] = burnFeeBps;
        idx.flashFeeBps = 0;
        idx.token = token;
        idx.paused = false;
    }

    function setIndexPoolId(uint256 indexId, uint256 pid) external {
        s().indexToPoolId[indexId] = pid;
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function feeIndexRemainder(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndexRemainder;
    }

    function feePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }

    function poolFeeShareBps() external view returns (uint16) {
        return _poolFeeShareBps();
    }

    function totalDeposits(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }
}

contract EqualIndexFeeSplitAccuracyPropertyTest is Test {
    uint256 private constant ASSET_POOL_ID = 1;
    uint256 private constant INDEX_POOL_ID = 2;
    uint256 private constant INDEX_ID = 0;
    uint16 private constant MINT_FEE_BPS = 200;
    uint16 private constant BURN_FEE_BPS = 100;

    function testFuzz_feeSplitAccuracyOnMintAndBurn(uint256 unitsRaw) public {
        uint256 units = _boundUnits(unitsRaw);
        MockERC20 asset = new MockERC20("Asset", "AST", 18, 0);

        EqualIndexFeeSplitAccuracyHarness facet = new EqualIndexFeeSplitAccuracyHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        address owner = address(0xBEEF);
        uint256 tokenId = nft.mint(owner, 1);
        facet.setPositionNFT(address(nft));

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.seedPool(ASSET_POOL_ID, address(asset), 1_000_000 ether);
        facet.setUser(ASSET_POOL_ID, positionKey, 500_000 ether);
        facet.joinPool(positionKey, ASSET_POOL_ID);
        facet.setAssetToPoolId(address(asset), ASSET_POOL_ID);

        IndexToken token = new IndexToken(
            "Index",
            "IDX",
            address(facet),
            _assets(asset),
            _bundle(),
            0,
            INDEX_ID
        );
        facet.seedPool(INDEX_POOL_ID, address(token), 0);
        facet.setAssetToPoolId(address(token), INDEX_POOL_ID);
        facet.setIndexPoolId(INDEX_ID, INDEX_POOL_ID);
        facet.setIndex(INDEX_ID, address(token), _assets(asset), _bundle(), MINT_FEE_BPS, BURN_FEE_BPS);

        uint256 totalBeforeMint = facet.totalDeposits(ASSET_POOL_ID);
        uint256 feeIndexBefore = facet.feeIndex(ASSET_POOL_ID);
        uint256 remainderBefore = facet.feeIndexRemainder(ASSET_POOL_ID);
        uint256 potBefore = facet.feePot(INDEX_ID, address(asset));

        vm.prank(owner);
        facet.mintFromPosition(tokenId, INDEX_ID, units);

        uint256 required = (1 ether * units) / LibEqualIndex.INDEX_SCALE;
        uint256 mintFee = (required * MINT_FEE_BPS) / 10_000;
        uint256 mintPoolShare = (mintFee * facet.poolFeeShareBps()) / 10_000;

        uint256 potAfterMint = facet.feePot(INDEX_ID, address(asset));
        assertEq(potAfterMint - potBefore, mintFee - mintPoolShare);

        uint256 totalAfterMint = totalBeforeMint - mintFee;
        uint256 feeIndexAfterMint = facet.feeIndex(ASSET_POOL_ID);
        uint256 remainderAfterMint = facet.feeIndexRemainder(ASSET_POOL_ID);
        uint256 mintScaled = mintPoolShare * 1e18;
        uint256 mintDividend = mintScaled + remainderBefore;
        uint256 mintDelta = mintDividend / totalAfterMint;
        uint256 mintRemainder = mintDividend - (mintDelta * totalAfterMint);
        assertEq(feeIndexAfterMint, feeIndexBefore + mintDelta);
        assertEq(remainderAfterMint, mintRemainder);

        uint256 totalBeforeBurn = facet.totalDeposits(ASSET_POOL_ID);
        uint256 feeIndexBeforeBurn = facet.feeIndex(ASSET_POOL_ID);
        uint256 remainderBeforeBurn = facet.feeIndexRemainder(ASSET_POOL_ID);
        uint256 potBeforeBurn = facet.feePot(INDEX_ID, address(asset));

        vm.prank(owner);
        facet.burnFromPosition(tokenId, INDEX_ID, units);

        uint256 gross = required + potBeforeBurn;
        uint256 burnFee = (gross * BURN_FEE_BPS) / 10_000;
        uint256 burnPoolShare = (burnFee * facet.poolFeeShareBps()) / 10_000;
        uint256 potAfterBurn = facet.feePot(INDEX_ID, address(asset));
        assertEq(potAfterBurn, burnFee - burnPoolShare);

        uint256 totalAfterBurn = totalBeforeBurn;
        uint256 feeIndexAfterBurn = facet.feeIndex(ASSET_POOL_ID);
        uint256 remainderAfterBurn = facet.feeIndexRemainder(ASSET_POOL_ID);
        uint256 burnScaled = burnPoolShare * 1e18;
        uint256 burnDividend = burnScaled + remainderBeforeBurn;
        uint256 burnDelta = burnDividend / totalAfterBurn;
        uint256 burnRemainder = burnDividend - (burnDelta * totalAfterBurn);
        assertEq(feeIndexAfterBurn, feeIndexBeforeBurn + burnDelta);
        assertEq(remainderAfterBurn, burnRemainder);
    }

    function _assets(MockERC20 asset) internal pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = address(asset);
    }

    function _bundle() internal pure returns (uint256[] memory bundle) {
        bundle = new uint256[](1);
        bundle[0] = 1 ether;
    }

    function _boundUnits(uint256 unitsRaw) internal pure returns (uint256) {
        uint256 units = unitsRaw % (1000 * LibEqualIndex.INDEX_SCALE);
        if (units == 0) {
            units = LibEqualIndex.INDEX_SCALE;
        }
        units = (units / LibEqualIndex.INDEX_SCALE) * LibEqualIndex.INDEX_SCALE;
        if (units == 0) {
            units = LibEqualIndex.INDEX_SCALE;
        }
        return units;
    }
}
