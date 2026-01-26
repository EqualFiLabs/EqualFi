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

contract EqualIndexPositionBurnHarness is EqualIndexPositionFacet {
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

    function setMembership(bytes32 positionKey, uint256 pid, bool joined) external {
        LibPoolMembership.PoolMembershipStorage storage ps = LibPoolMembership.s();
        ps.joined[positionKey][pid] = joined;
    }

    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function setIndex(
        uint256 indexId,
        address token,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16[] memory mintFees,
        uint16[] memory burnFees
    ) external {
        EqualIndexStorage storage es = s();
        if (es.indexCount <= indexId) {
            es.indexCount = indexId + 1;
        }
        Index storage idx = es.indexes[indexId];
        idx.assets = assets;
        idx.bundleAmounts = bundleAmounts;
        idx.mintFeeBps = mintFees;
        idx.burnFeeBps = burnFees;
        idx.flashFeeBps = 0;
        idx.token = token;
        idx.paused = false;
    }

    function setIndexPoolId(uint256 indexId, uint256 pid) external {
        s().indexToPoolId[indexId] = pid;
    }
}

contract EqualIndexPositionBurnPropertyTest is Test {
    function testFuzz_noExternalTransfersOnBurn(uint256 unitsRaw) public {
        uint256 units = _boundUnits(unitsRaw);
        (EqualIndexPositionBurnHarness facet, PositionNFT nft, uint256 tokenId, address owner, MockERC20 assetA, MockERC20 assetB) =
            _setup(units);

        uint256 balA = assetA.balanceOf(address(facet));
        uint256 balB = assetB.balanceOf(address(facet));

        vm.prank(owner);
        facet.burnFromPosition(tokenId, 0, units);

        assertEq(assetA.balanceOf(address(facet)), balA);
        assertEq(assetB.balanceOf(address(facet)), balB);
    }

    function testFuzz_burnAutoJoinsUnderlyingPools(uint256 unitsRaw) public {
        uint256 units = _boundUnits(unitsRaw);
        (EqualIndexPositionBurnHarness facet, PositionNFT nft, uint256 tokenId, address owner,, MockERC20 assetB) =
            _setup(units);

        bytes32 positionKey = nft.getPositionKey(tokenId);
        facet.setMembership(positionKey, 2, false);
        assertFalse(facet.isMember(positionKey, 2));

        vm.prank(owner);
        facet.burnFromPosition(tokenId, 0, units);

        assertTrue(facet.isMember(positionKey, 2));
    }

    function _setup(uint256 units)
        internal
        returns (
            EqualIndexPositionBurnHarness facet,
            PositionNFT nft,
            uint256 tokenId,
            address owner,
            MockERC20 assetA,
            MockERC20 assetB
        )
    {
        assetA = new MockERC20("AssetA", "A", 18, 0);
        assetB = new MockERC20("AssetB", "B", 18, 0);

        facet = new EqualIndexPositionBurnHarness();
        nft = new PositionNFT();
        nft.setMinter(address(this));
        owner = address(0xBEEF);
        tokenId = nft.mint(owner, 1);
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

        IndexToken token = new IndexToken(
            "Index",
            "IDX",
            address(facet),
            _assets(assetA, assetB),
            _bundle(),
            0,
            0
        );
        facet.seedPool(9, address(token), 0);
        facet.setAssetToPoolId(address(token), 9);
        facet.setIndexPoolId(0, 9);
        facet.setIndex(0, address(token), _assets(assetA, assetB), _bundle(), _mintFees(), _burnFees());

        vm.prank(owner);
        facet.mintFromPosition(tokenId, 0, units);

        return (facet, nft, tokenId, owner, assetA, assetB);
    }

    function _assets(MockERC20 assetA, MockERC20 assetB) internal pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
    }

    function _bundle() internal pure returns (uint256[] memory bundle) {
        bundle = new uint256[](2);
        bundle[0] = 1 ether;
        bundle[1] = 2 ether;
    }

    function _mintFees() internal pure returns (uint16[] memory mintFees) {
        mintFees = new uint16[](2);
        mintFees[0] = 200;
        mintFees[1] = 100;
    }

    function _burnFees() internal pure returns (uint16[] memory burnFees) {
        burnFees = new uint16[](2);
        burnFees[0] = 200;
        burnFees[1] = 100;
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
