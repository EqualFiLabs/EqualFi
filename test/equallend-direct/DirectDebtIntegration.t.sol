// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// forge-config: default.optimizer = false

import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

interface IPositionManagement {
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external returns (uint256);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
    function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
}

/// @notice Property tests ensuring direct debt participates in solvency/withdrawal guards
contract DirectDebtIntegrationPropertyTest is DirectDiamondTestBase {
    IPositionManagement internal pm;
    MockERC20 internal token;

    address internal user = address(0xA11CE);

    uint256 constant PID = 1;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint16 constant LTV_BPS = 8000;

    struct DebtContext {
        uint256 tokenId;
        bytes32 key;
        uint256 principal;
    }

    function setUp() public {
        setUpDiamond();
        _addPositionManagementFacet();
        pm = IPositionManagement(address(diamond));
        token = new MockERC20("Test Token", "TEST", 18, INITIAL_SUPPLY);
        finalizePositionNFT();

        harness.initPool(PID, address(token), 1, 1, LTV_BPS);

        token.transfer(user, INITIAL_SUPPLY / 2);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);
    }

    function testFuzz_DirectDebtRestrictsWithdrawals(
        uint256 depositAmount,
        uint256 directLocked,
        uint256 directBorrowed,
        uint256 withdrawAmount
    ) public {
        DebtContext memory ctx = _mintPosition(bound(depositAmount, 10 ether, 200_000 ether));
        directLocked = _applyDirectState(ctx, directLocked, directBorrowed);
        _tryWithdraw(ctx, withdrawAmount);
        _assertSolvency(ctx);
    }

    function test_DirectBorrowedCountsAsDebt() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPositionWithDeposit(PID, 100 ether);
        bytes32 key = nft.getPositionKey(tokenId);
        vm.stopPrank();

        // Borrow 50; only direct borrowed principal should count as debt.
        harness.setDirectState(key, PID, 40 ether, 10 ether, 50 ether);

        uint256 totalDebt = views.getTotalDebt(PID, key);
        assertEq(totalDebt, 50 ether, "direct borrowed principal treated as debt");
    }

    function _mintPosition(uint256 depositAmount) internal returns (DebtContext memory ctx) {
        vm.startPrank(user);
        ctx.tokenId = pm.mintPositionWithDeposit(PID, depositAmount);
        ctx.key = nft.getPositionKey(ctx.tokenId);
        vm.stopPrank();
        ctx.principal = views.getUserPrincipal(PID, ctx.key);
    }

    function _applyDirectState(DebtContext memory ctx, uint256 directLocked, uint256 directBorrowed)
        internal
        returns (uint256 normalizedLocked)
    {
        normalizedLocked = bound(directLocked, 0, ctx.principal);
        uint256 maxBorrowable = (ctx.principal * LTV_BPS) / 10_000;
        uint256 normalizedBorrowed = bound(directBorrowed, 0, maxBorrowable);
        harness.setDirectState(ctx.key, PID, normalizedLocked, 0, normalizedBorrowed);
        (uint256 locked,, uint256 borrowed) = views.directBalances(ctx.key, PID);
        assertEq(locked, normalizedLocked, "locked not set");
        assertEq(borrowed, normalizedBorrowed, "borrowed not set");
    }

    function _tryWithdraw(DebtContext memory ctx, uint256 withdrawAmount) internal {
        uint256 withdrawable = views.getWithdrawablePrincipal(PID, ctx.key);
        uint256 boundedWithdraw = bound(withdrawAmount, 0, withdrawable);
        if (boundedWithdraw == 0) return;

        vm.startPrank(user);
        try pm.withdrawFromPosition(ctx.tokenId, PID, boundedWithdraw) {
            vm.stopPrank();
        } catch {
            vm.stopPrank();
        }
    }

    function _assertSolvency(DebtContext memory ctx) internal {
        uint256 debt = views.getTotalDebt(PID, ctx.key);
        uint256 updatedPrincipal = views.getUserPrincipal(PID, ctx.key);
        uint256 updatedMaxBorrowable = (updatedPrincipal * LTV_BPS) / 10_000;
        assertLe(debt, updatedMaxBorrowable, "direct debt broke solvency");
    }

    function _addPositionManagementFacet() internal {
        PositionManagementFacet pmFacet = new PositionManagementFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = _cut(address(pmFacet), _selectorsPositionManagement());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
        s[2] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256)"));
    }
}

contract DirectGlobalLockIntegrationTest is DirectDiamondTestBase {
    MockERC20 internal token;

    IPositionManagement internal pm;

    address internal user = address(0xA11CE);
    uint256 constant PID_A = 1;
    uint256 constant PID_C = 2;
    uint16 constant LTV_BPS = 8000;

    function setUp() public {
        setUpDiamond();
        _addPositionManagementFacet();
        pm = IPositionManagement(address(diamond));
        token = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
        finalizePositionNFT();

        harness.initPool(PID_A, address(token), 1, 1, LTV_BPS);
        harness.initPool(PID_C, address(token), 1, 1, LTV_BPS);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);

        token.transfer(user, 500_000 ether);
        vm.prank(user);
        token.approve(address(diamond), type(uint256).max);
    }

    function test_GlobalDirectLockDoesNotBlockOtherPoolWithdraw() public {
        vm.startPrank(user);
        uint256 tokenId = pm.mintPositionWithDeposit(PID_A, 1000 ether);
        pm.depositToPosition(tokenId, PID_C, 800 ether);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: tokenId,
            lenderPoolId: PID_A,
            collateralPoolId: PID_A,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 100 ether,
            aprBps: 1200,
            durationSeconds: 7 days,
            collateralLockAmount: 900 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });
        offers.postBorrowerOffer(params);

        uint256 balanceBefore = token.balanceOf(user);
        pm.withdrawFromPosition(tokenId, PID_C, 800 ether);
        assertEq(token.balanceOf(user), balanceBefore + 800 ether, "pool C withdraw succeeds");
        vm.stopPrank();
    }
    function _addPositionManagementFacet() internal {
        PositionManagementFacet pmFacet = new PositionManagementFacet();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = _cut(address(pmFacet), _selectorsPositionManagement());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[1] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
        s[2] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256)"));
    }
}
