// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidityViewFacet} from "../../src/views/LiquidityViewFacet.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LiquidityViewHarness is LiquidityViewFacet {
    function seedPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
    }

    function setAccrued(uint256 pid, bytes32 key, uint256 accrued) external {
        LibAppStorage.s().pools[pid].userAccruedYield[key] = accrued;
    }
}

contract LiquidityViewFacetTest is Test {
    LiquidityViewHarness internal viewFacet;
    MockERC20 internal token;

    function setUp() public {
        viewFacet = new LiquidityViewHarness();
        token = new MockERC20("T", "T", 18, 0);
        viewFacet.seedPool(1, address(token));
    }

    function testSumAccruedYieldTotalsProvidedKeys() public {
        bytes32 keyA = keccak256("a");
        bytes32 keyB = keccak256("b");
        viewFacet.setAccrued(1, keyA, 10);
        viewFacet.setAccrued(1, keyB, 15);

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = keyA;
        keys[1] = keyB;

        uint256 total = viewFacet.sumAccruedYield(1, keys);
        assertEq(total, 25, "sum of accrued yield");
    }

    function testSumAccruedYieldEmptyListZero() public {
        bytes32[] memory keys = new bytes32[](0);
        uint256 total = viewFacet.sumAccruedYield(1, keys);
        assertEq(total, 0, "empty list yields zero");
    }
}
