// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibIndexEncumbrance} from "../../src/libraries/LibIndexEncumbrance.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract EqualIndexRoundTripHarness is EqualIndexPositionFacet {
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
        uint256[] memory bundleAmounts
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
        idx.flashFeeBps = 0;
        idx.token = token;
        idx.paused = false;
    }

    function setIndexPoolId(uint256 indexId, uint256 pid) external {
        s().indexToPoolId[indexId] = pid;
    }

    function getEncumbered(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibIndexEncumbrance.getEncumbered(positionKey, pid);
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }
}

contract EqualIndexRoundTripConservationPropertyTest is Test {
    function testFuzz_roundTripConservation(uint256 unitsRaw) public {
        uint256 units = _boundUnits(unitsRaw);
        MockERC20 asset = new MockERC20("Asset", "AST", 18, 0);

        EqualIndexRoundTripHarness facet = new EqualIndexRoundTripHarness();
        PositionNFT nft = new PositionNFT();
        nft.setMinter(address(this));
        address owner = address(0xBEEF);
        uint256 tokenId = nft.mint(owner, 1);
        facet.setPositionNFT(address(nft));

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.seedPool(1, address(asset), 10_000 ether);
        facet.setUser(1, positionKey, 5_000 ether);
        facet.joinPool(positionKey, 1);
        facet.setAssetToPoolId(address(asset), 1);

        IndexToken token = new IndexToken(
            "Index",
            "IDX",
            address(facet),
            _assets(asset),
            _bundle(),
            0,
            0
        );
        facet.seedPool(9, address(token), 0);
        facet.setAssetToPoolId(address(token), 9);
        facet.setIndexPoolId(0, 9);
        facet.setIndex(0, address(token), _assets(asset), _bundle());

        uint256 encBefore = facet.getEncumbered(positionKey, 1);
        uint256 vaultBefore = facet.getVaultBalance(0, address(asset));

        vm.prank(owner);
        facet.mintFromPosition(tokenId, 0, units);

        vm.prank(owner);
        facet.burnFromPosition(tokenId, 0, units);

        uint256 encAfter = facet.getEncumbered(positionKey, 1);
        uint256 vaultAfter = facet.getVaultBalance(0, address(asset));

        assertEq(encAfter, encBefore);
        assertEq(vaultAfter, vaultBefore);
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
