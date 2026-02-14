// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {LendingFacet} from "../src/equallend/LendingFacet.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../src/libraries/LibPositionNFT.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

// Minimal local harness (adapted from echidna) to reproduce the liquidity invariant failure.
contract MockPositionNFT {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function ownerOf(uint256) external view returns (address) {
        return owner;
    }

    function getPositionKey(uint256 tokenId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenId));
    }

    function getPoolId(uint256) external pure returns (uint256) {
        return 1;
    }
}

contract ReproLendingHarness is LendingFacet {
    MockERC20 internal token;
    MockPositionNFT internal mockNft;

    uint256 internal constant PID = 1;
    uint256 internal constant TOKEN_ID = 1;

    constructor() {
        token = new MockERC20("Test", "TEST", 18, 1_000_000 ether);
        mockNft = new MockPositionNFT(msg.sender);

        LibPositionNFT.PositionNFTStorage storage pns = LibPositionNFT.s();
        pns.positionNFTContract = address(mockNft);
        pns.nftModeEnabled = true;

        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        p.initialized = true;
        p.underlying = address(token);
        p.poolConfig.depositorLTVBps = 5000;
        p.poolConfig.minLoanAmount = 100;
        p.poolConfig.minTopupAmount = 100;

        p.trackedBalance = 1_000_000 ether;
        p.totalDeposits = 1_000_000 ether;
    }

    function action_deposit(uint128 amount) public {
        if (amount == 0) return;

        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];

        bytes32 posKey = mockNft.getPositionKey(TOKEN_ID);
        p.userPrincipal[posKey] += amount;
        p.totalDeposits += amount;
        p.trackedBalance += amount;

        token.mint(address(this), amount);
    }

    function action_borrow(uint128 amount) public {
        super.openRollingFromPosition(TOKEN_ID, PID, amount, amount);
    }

    function echidna_liquidity_invariant() public view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];

        uint256 actualBalance = token.balanceOf(address(this));
        uint256 internalTotal = p.trackedBalance + p.yieldReserve + p.feeIndexRemainder;

        return actualBalance == internalTotal;
    }

    function debug_accounting() public view returns (uint256 tracked, uint256 reserve, uint256 remainder, uint256 actual) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        Types.PoolData storage p = s.pools[PID];
        tracked = p.trackedBalance;
        reserve = p.yieldReserve;
        remainder = p.feeIndexRemainder;
        actual = token.balanceOf(address(this));
    }
}

contract ReproduceLiquidityFailure is Test {
    ReproLendingHarness facet;

    function setUp() public {
        facet = new ReproLendingHarness();
    }

    function test_ReproduceInvariantFailure() public {
        uint128 depositAmount = 1346746830706240228723223072239472304;
        uint128 borrowAmount = 256;

        console2.log("=== Initial State ===");
        logState();

        console2.log(">>> Action: Deposit", depositAmount);
        facet.action_deposit(depositAmount);
        logState();

        console2.log(">>> Action: Borrow", borrowAmount);
        facet.action_borrow(borrowAmount);
        logState();

        bool invariant = facet.echidna_liquidity_invariant();
        console2.log("Invariant passed?", invariant);
        
        assertTrue(invariant, "Liquidity invariant failed");
    }

    function logState() internal view {
        (uint256 tracked, uint256 reserve, uint256 remainder, uint256 actual) = facet.debug_accounting();
        console2.log("Tracked:  ", tracked);
        console2.log("Reserve:  ", reserve);
        console2.log("Remainder:", remainder);
        console2.log("Internal: ", tracked + reserve + remainder);
        console2.log("Actual:   ", actual);
        int256 diff = int256(tracked + reserve + remainder) - int256(actual);
        console2.log("Diff:     ");
        console2.logInt(diff);
    }
}
