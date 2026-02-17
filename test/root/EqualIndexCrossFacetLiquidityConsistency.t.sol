// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {EqualIndexPositionFacet} from "../../src/equalindex/EqualIndexPositionFacet.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract PositionManagementCrossFacetHarness is PositionManagementFacet {
    function configurePositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function initPool(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint16 ltvBps,
        uint256 trackedBalance,
        uint256 totalDeposits
    ) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.minDepositAmount = minDeposit;
        p.poolConfig.minLoanAmount = minLoan;
        p.poolConfig.depositorLTVBps = ltvBps;
        p.trackedBalance = trackedBalance;
        p.totalDeposits = totalDeposits;
        p.feeIndex = LibFeeIndex.INDEX_SCALE;
        p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        s().assetToPoolId[asset] = pid;
    }

    function principalOf(uint256 pid, bytes32 key) external view returns (uint256) {
        return s().pools[pid].userPrincipal[key];
    }

    function trackedBalance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].trackedBalance;
    }
}

contract EqualIndexPositionCrossFacetHarness is EqualIndexPositionFacet {
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

    function feePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }
}

interface IPositionManagementCrossFacet {
    function configurePositionNFT(address nft) external;
    function initPool(
        uint256 pid,
        address underlying,
        uint256 minDeposit,
        uint256 minLoan,
        uint16 ltvBps,
        uint256 trackedBalance,
        uint256 totalDeposits
    ) external;
    function setAssetToPoolId(address asset, uint256 pid) external;
    function mintPosition(uint256 pid, uint256 maxFee) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount, uint256 maxAmount) external;
    function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 amount, uint256 minReceived) external;
    function principalOf(uint256 pid, bytes32 key) external view returns (uint256);
    function trackedBalance(uint256 pid) external view returns (uint256);
}

interface IEqualIndexPositionCrossFacet {
    function setIndex(
        uint256 indexId,
        address token,
        address[] memory assets,
        uint256[] memory bundleAmounts,
        uint16 mintFeeBps,
        uint16 burnFeeBps
    ) external;
    function setIndexPoolId(uint256 indexId, uint256 pid) external;
    function mintFromPosition(uint256 positionId, uint256 indexId, uint256 units) external returns (uint256 minted);
    function burnFromPosition(uint256 positionId, uint256 indexId, uint256 units)
        external
        returns (uint256[] memory assetsOut);
    function feePot(uint256 indexId, address asset) external view returns (uint256);
}

contract EqualIndexCrossFacetLiquidityConsistencyTest is Test {
    Diamond internal diamond;
    PositionNFT internal nft;
    MockERC20 internal asset;

    IPositionManagementCrossFacet internal pm;
    IEqualIndexPositionCrossFacet internal idx;

    address internal user = address(0xA11CE);

    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant INDEX_PID = 2;
    uint256 internal constant INDEX_ID = 0;
    uint256 internal constant UNITS = LibEqualIndex.INDEX_SCALE;
    uint256 internal constant DEPOSIT_AMOUNT = 1000;

    function setUp() public {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();
        PositionManagementCrossFacetHarness pmFacet = new PositionManagementCrossFacetHarness();
        EqualIndexPositionCrossFacetHarness idxFacet = new EqualIndexPositionCrossFacetHarness();

        IDiamondCut.FacetCut[] memory baseCuts = new IDiamondCut.FacetCut[](3);
        baseCuts[0] = _cut(address(cut), _selectors(cut));
        baseCuts[1] = _cut(address(loupe), _selectors(loupe));
        baseCuts[2] = _cut(address(own), _selectors(own));
        diamond = new Diamond(baseCuts, Diamond.DiamondArgs({owner: address(this)}));

        IDiamondCut.FacetCut[] memory added = new IDiamondCut.FacetCut[](2);
        added[0] = _cut(address(pmFacet), _selectors(pmFacet));
        added[1] = _cut(address(idxFacet), _selectors(idxFacet));
        IDiamondCut(address(diamond)).diamondCut(added, address(0), "");

        pm = IPositionManagementCrossFacet(address(diamond));
        idx = IEqualIndexPositionCrossFacet(address(diamond));

        nft = new PositionNFT();
        asset = new MockERC20("Asset", "AST", 18, 0);

        pm.configurePositionNFT(address(nft));
        nft.setMinter(address(diamond));
        nft.setDiamond(address(diamond));

        pm.initPool(UNDERLYING_PID, address(asset), 1, 1, 10_000, 0, 0);
        pm.setAssetToPoolId(address(asset), UNDERLYING_PID);

        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint256[] memory bundle = new uint256[](1);
        // 100 with 1% mint fee => fee=1, so poolShare floors to 0 and all fee enters fee pot.
        bundle[0] = 100;
        IndexToken indexToken = new IndexToken("Index", "IDX", address(diamond), assets, bundle, 0, INDEX_ID);

        pm.initPool(INDEX_PID, address(indexToken), 1, 1, 10_000, 0, 0);
        pm.setAssetToPoolId(address(indexToken), INDEX_PID);
        idx.setIndexPoolId(INDEX_ID, INDEX_PID);
        idx.setIndex(INDEX_ID, address(indexToken), assets, bundle, 100, 0);

        asset.mint(user, 1_000_000 ether);
        vm.prank(user);
        asset.approve(address(diamond), type(uint256).max);
    }

    function test_crossFacetMintBurnWithdraw_hasNoTrackedLiquidityShortfall() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPosition(UNDERLYING_PID, 0);
        pm.depositToPosition(tokenId, UNDERLYING_PID, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        idx.mintFromPosition(tokenId, INDEX_ID, UNITS);
        assertEq(idx.feePot(INDEX_ID, address(asset)), 1, "fee pot should be seeded");

        idx.burnFromPosition(tokenId, INDEX_ID, UNITS);
        vm.stopPrank();

        bytes32 key = nft.getPositionKey(tokenId);
        uint256 principalAfterBurn = pm.principalOf(UNDERLYING_PID, key);
        uint256 trackedAfterBurn = pm.trackedBalance(UNDERLYING_PID);
        assertEq(principalAfterBurn, DEPOSIT_AMOUNT, "principal should be fully restored after round-trip");
        assertEq(trackedAfterBurn, principalAfterBurn, "tracked balance must back principal exactly");

        vm.prank(user);
        pm.withdrawFromPosition(tokenId, UNDERLYING_PID, principalAfterBurn, 0);

        assertEq(pm.principalOf(UNDERLYING_PID, key), 0, "principal should be withdrawable without shortfall");
        assertEq(pm.trackedBalance(UNDERLYING_PID), 0, "tracked should drain with principal withdrawal");
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

    function _selectors(PositionManagementCrossFacetHarness) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = PositionManagementCrossFacetHarness.configurePositionNFT.selector;
        s[1] = PositionManagementCrossFacetHarness.initPool.selector;
        s[2] = PositionManagementCrossFacetHarness.setAssetToPoolId.selector;
        s[3] = PositionManagementFacet.mintPosition.selector;
        s[4] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256,uint256)"));
        s[5] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256,uint256)"));
        s[6] = PositionManagementCrossFacetHarness.principalOf.selector;
        s[7] = PositionManagementCrossFacetHarness.trackedBalance.selector;
        s[8] = PositionManagementFacet.cleanupMembership.selector;
    }

    function _selectors(EqualIndexPositionCrossFacetHarness) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = EqualIndexPositionCrossFacetHarness.setIndex.selector;
        s[1] = EqualIndexPositionCrossFacetHarness.setIndexPoolId.selector;
        s[2] = EqualIndexPositionFacet.mintFromPosition.selector;
        s[3] = EqualIndexPositionFacet.burnFromPosition.selector;
        s[4] = EqualIndexPositionCrossFacetHarness.feePot.selector;
    }
}
