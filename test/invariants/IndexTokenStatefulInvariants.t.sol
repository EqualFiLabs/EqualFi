// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {EqualIndexActionsHarness} from "../root/EqualIndexActionsFacetV3.t.sol";
import {IndexToken} from "../../src/equalindex/IndexToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract IndexInvariantHarness is EqualIndexActionsHarness {
    function getTotalUnits(uint256 indexId) external view returns (uint256) {
        return s().indexes[indexId].totalUnits;
    }
}

contract IndexTokenStatefulHandler is Test {
    IndexInvariantHarness internal facet;
    IndexToken internal indexToken;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal user;
    uint256 internal indexId;
    uint256 internal scale;

    uint256 internal bundleAmountA;
    uint256 internal bundleAmountB;
    uint16 internal mintFeeA;
    uint16 internal mintFeeB;

    constructor(
        IndexInvariantHarness facet_,
        IndexToken indexToken_,
        MockERC20 tokenA_,
        MockERC20 tokenB_,
        address user_,
        uint256 indexId_,
        uint256 scale_,
        uint256 bundleAmountA_,
        uint256 bundleAmountB_,
        uint16 mintFeeA_,
        uint16 mintFeeB_
    ) {
        facet = facet_;
        indexToken = indexToken_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        user = user_;
        indexId = indexId_;
        scale = scale_;
        bundleAmountA = bundleAmountA_;
        bundleAmountB = bundleAmountB_;
        mintFeeA = mintFeeA_;
        mintFeeB = mintFeeB_;
    }

    function mint(uint256 unitsSeed) external {
        uint256 units = _boundUnits(unitsSeed);
        if (units == 0) {
            return;
        }
        _topUpForMint(units);
        vm.prank(user);
        facet.mint(indexId, units, user);
    }

    function burn(uint256 unitsSeed) external {
        uint256 balance = indexToken.balanceOf(user);
        if (balance < scale) {
            return;
        }
        uint256 unitCount = bound(unitsSeed, 1, balance / scale);
        uint256 units = unitCount * scale;
        vm.prank(user);
        facet.burn(indexId, units, user);
    }

    function _boundUnits(uint256 unitsSeed) internal view returns (uint256) {
        uint256 unitCount = bound(unitsSeed, 1, 1_000);
        return unitCount * scale;
    }

    function _topUpForMint(uint256 units) internal {
        uint256 unitCount = units / scale;
        uint256 needA = bundleAmountA * unitCount;
        uint256 needB = bundleAmountB * unitCount;
        uint256 feeA = (needA * mintFeeA) / 10_000;
        uint256 feeB = (needB * mintFeeB) / 10_000;
        uint256 totalA = needA + feeA;
        uint256 totalB = needB + feeB;

        if (tokenA.balanceOf(user) < totalA) {
            tokenA.mint(user, totalA - tokenA.balanceOf(user));
        }
        if (tokenB.balanceOf(user) < totalB) {
            tokenB.mint(user, totalB - tokenB.balanceOf(user));
        }
    }
}

contract IndexTokenStatefulInvariantTest is StdInvariant, Test {
    IndexInvariantHarness internal facet;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    IndexToken internal indexToken;
    IndexTokenStatefulHandler internal handler;

    address internal user = address(0xB0B);

    uint256 internal constant INDEX_ID = 1;
    uint256 internal constant SCALE = 1e18;

    uint256 internal bundleAmountA;
    uint256 internal bundleAmountB;

    function setUp() public {
        facet = new IndexInvariantHarness();
        tokenA = new MockERC20("Token A", "TKA", 18, 0);
        tokenB = new MockERC20("Token B", "TKB", 18, 0);

        bundleAmountA = 10 * SCALE;
        bundleAmountB = 20 * SCALE;

        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);

        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = bundleAmountA;
        bundleAmounts[1] = bundleAmountB;

        indexToken = new IndexToken(
            "Index Token",
            "IDX",
            address(facet),
            assets,
            bundleAmounts,
            0,
            INDEX_ID
        );

        uint16[] memory mintFees = new uint16[](2);
        mintFees[0] = 100;
        mintFees[1] = 100;

        uint16[] memory burnFees = new uint16[](2);
        burnFees[0] = 50;
        burnFees[1] = 50;

        facet.initIndex(INDEX_ID, assets, bundleAmounts, mintFees, burnFees, 10, address(indexToken));
        facet.setTreasury(address(0x999));
        facet.setAssetPool(address(tokenA), 1, 1_000_000 * SCALE);
        facet.setAssetPool(address(tokenB), 2, 1_000_000 * SCALE);

        tokenA.mint(user, 1_000_000 * SCALE);
        tokenB.mint(user, 1_000_000 * SCALE);
        vm.prank(user);
        tokenA.approve(address(facet), type(uint256).max);
        vm.prank(user);
        tokenB.approve(address(facet), type(uint256).max);

        handler = new IndexTokenStatefulHandler(
            facet,
            indexToken,
            tokenA,
            tokenB,
            user,
            INDEX_ID,
            SCALE,
            bundleAmountA,
            bundleAmountB,
            mintFees[0],
            mintFees[1]
        );
        targetContract(address(handler));
    }

    function invariant_totalSupplyMatchesUnits() public {
        assertEq(indexToken.totalSupply(), facet.getTotalUnits(INDEX_ID));
    }

    function invariant_vaultBalancesMatchSupply() public {
        uint256 totalUnits = facet.getTotalUnits(INDEX_ID);
        uint256 expectedA = (totalUnits * bundleAmountA) / SCALE;
        uint256 expectedB = (totalUnits * bundleAmountB) / SCALE;

        assertEq(facet.getVaultBalance(INDEX_ID, address(tokenA)), expectedA);
        assertEq(facet.getVaultBalance(INDEX_ID, address(tokenB)), expectedB);
    }
}
