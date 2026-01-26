// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

interface IDirectFacet {
    function acceptOffer(uint256 offerId, uint256 borrowerPositionId) external returns (uint256);
    function repay(uint256 agreementId) external;
    function recover(uint256 agreementId) external;
}

contract ReenteringERC20 is MockERC20 {
    enum Mode {
        None,
        Accept,
        Repay,
        Recover
    }

    Mode public mode;
    IDirectFacet public target;
    uint256 public offerId;
    uint256 public borrowerPositionId;
    uint256 public agreementId;
    bool internal entered;

    constructor() MockERC20("Malicious", "MAL", 18, 0) {}

    function setReentrancyTarget(
        IDirectFacet _target,
        Mode _mode,
        uint256 _offerId,
        uint256 _borrowerPositionId,
        uint256 _agreementId
    ) external {
        target = _target;
        mode = _mode;
        offerId = _offerId;
        borrowerPositionId = _borrowerPositionId;
        agreementId = _agreementId;
        entered = false;
    }

    function _maybeReenter() internal {
        if (entered || mode == Mode.None || address(target) == address(0)) return;
        entered = true;
        if (mode == Mode.Accept) {
            target.acceptOffer(offerId, borrowerPositionId);
        } else if (mode == Mode.Repay) {
            target.repay(agreementId);
        } else if (mode == Mode.Recover) {
            target.recover(agreementId);
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _maybeReenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _maybeReenter();
        return super.transferFrom(from, to, amount);
    }
}

contract DirectConfigEdgeTest is DirectDiamondTestBase {
    PositionNFT internal nftContract;
    ReenteringERC20 internal token;

    address internal lender = address(0xBEEF);
    address internal borrower = address(0xA11CE);
    address internal treasury = address(0x9999);

    uint256 constant LENDER_PID = 1;
    uint256 constant BORROWER_PID = 2;

    function setUp() public {
        setUpDiamond();
        nftContract = nft;
        token = new ReenteringERC20();

        harness.initPool(LENDER_PID, address(token));
        harness.initPool(BORROWER_PID, address(token));

        // Mint liquidity for testing
        token.mint(address(diamond), 1_000_000 ether);
        token.mint(lender, 500_000 ether);
        token.mint(borrower, 500_000 ether);
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function _mintPosition(address to, uint256 pid) internal returns (uint256 tokenId, bytes32 key) {
        tokenId = nft.mint(to, pid);
        key = nft.getPositionKey(tokenId);
        harness.seedPosition(pid, key, 200 ether);
        vm.prank(to);
        token.approve(address(diamond), type(uint256).max);
    }

    function _defaultConfig() internal pure returns (DirectTypes.DirectConfig memory cfg) {
        cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5_000,
            defaultLenderBps: 8_000,
            minInterestDuration: 0
        });
    }

    function test_acceptOfferRevertsWhenProtocolTreasuryUnsetWithPlatformFee() public {
        (uint256 lenderTokenId, bytes32 lenderKey) = _mintPosition(lender, LENDER_PID);
        (uint256 borrowerTokenId, bytes32 borrowerKey) = _mintPosition(borrower, BORROWER_PID);
        _finalizeMinter();
        harness.setConfig(
            DirectTypes.DirectConfig({
                platformFeeBps: 500,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 5_000,
                defaultLenderBps: 8_000,
                minInterestDuration: 0
            })
        );

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: LENDER_PID,
            collateralPoolId: BORROWER_PID,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 50 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lender);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement active");
        (, , uint256 borrowed) = views.directBalances(borrowerKey, LENDER_PID);
        assertEq(borrowed, params.principal, "borrower debt recorded");
    }

    function test_acceptOfferSucceedsWithZeroPlatformFeeAndSplits() public {
        (uint256 lenderTokenId, bytes32 lenderKey) = _mintPosition(lender, LENDER_PID);
        (uint256 borrowerTokenId, bytes32 borrowerKey) = _mintPosition(borrower, BORROWER_PID);
        _finalizeMinter();
        harness.setConfig(_defaultConfig());

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: LENDER_PID,
            collateralPoolId: BORROWER_PID,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 40 ether,
            aprBps: 1000,
            durationSeconds: 30 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lender);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        uint256 lenderBalanceBefore = token.balanceOf(lender);
        uint256 borrowerBalanceBefore = token.balanceOf(borrower);

        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);

        DirectTypes.DirectOffer memory offer = views.getOffer(offerId);
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertTrue(offer.filled, "offer should be filled");
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement active");
        (uint256 locked,,) = views.directBalances(borrowerKey, BORROWER_PID);
        assertEq(locked, 10 ether, "collateral locked");
        uint256 interest = DirectTestUtils.annualizedInterest(params);
        assertEq(token.balanceOf(lender) - lenderBalanceBefore, 0, "lender EOA unchanged");
        assertEq(views.accruedYield(LENDER_PID, lenderKey), interest, "lender yield credited");
        assertEq(
            token.balanceOf(borrower) - borrowerBalanceBefore,
            params.principal - interest,
            "borrower received principal minus interest"
        );
        assertEq(token.balanceOf(treasury), 0, "treasury untouched when platform fee zero");
    }

    function test_acceptOfferBlocksReentrancyFromTokenCallback() public {
        (uint256 lenderTokenId,) = _mintPosition(lender, LENDER_PID);
        (uint256 borrowerTokenId, bytes32 borrowerKey) = _mintPosition(borrower, BORROWER_PID);
        _finalizeMinter();
        harness.setConfig(_defaultConfig());
        harness.setTreasuryShare(treasury, 5000);
        harness.setActiveCreditShare(0);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: LENDER_PID,
            collateralPoolId: BORROWER_PID,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 30 ether,
            aprBps: 1000,
            durationSeconds: 10 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lender);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        token.setReentrancyTarget(IDirectFacet(address(diamond)), ReenteringERC20.Mode.Accept, offerId, borrowerTokenId, 0);

        vm.prank(borrower);
        vm.expectRevert();
        agreements.acceptOffer(offerId, borrowerTokenId);

        DirectTypes.DirectOffer memory offer = views.getOffer(offerId);
        (uint256 locked,,) = views.directBalances(borrowerKey, BORROWER_PID);
        assertFalse(offer.filled, "offer not filled");
        assertEq(locked, 0, "no collateral locked");
    }

    function test_repayBlocksReentrancyFromTokenCallback() public {
        (uint256 lenderTokenId, bytes32 lenderKey) = _mintPosition(lender, LENDER_PID);
        (uint256 borrowerTokenId, bytes32 borrowerKey) = _mintPosition(borrower, BORROWER_PID);
        _finalizeMinter();
        harness.setConfig(_defaultConfig());
        harness.setTreasuryShare(treasury, 5000);
        harness.setActiveCreditShare(0);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: LENDER_PID,
            collateralPoolId: BORROWER_PID,
            collateralAsset: address(token),
            borrowAsset: address(token),
            principal: 20 ether,
            aprBps: 1000,
            durationSeconds: 5 days,
            collateralLockAmount: 5 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lender);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);

        (uint256 locked,,) = views.directBalances(borrowerKey, BORROWER_PID);
        (, , uint256 borrowed) = views.directBalances(borrowerKey, LENDER_PID);
        (, uint256 lenderLent,) = views.directBalances(lenderKey, LENDER_PID);
        assertEq(borrowed, 20 ether, "borrow recorded");
        assertEq(lenderLent, 20 ether, "lent recorded");
        assertEq(locked, 5 ether, "collateral locked");

        token.setReentrancyTarget(IDirectFacet(address(diamond)), ReenteringERC20.Mode.Repay, 0, 0, agreementId);
        vm.prank(borrower);
        vm.expectRevert();
        lifecycle.repay(agreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement should remain active");
    }

    function test_recoverBlocksReentrancyFromTokenCallback() public {
        // Fresh tokens to hit ERC20 transfers in recover
        ReenteringERC20 collateral = new ReenteringERC20();
        MockERC20 borrowToken = new MockERC20("Borrow", "BORR", 18, 0);

        harness.initPool(LENDER_PID, address(borrowToken));
        harness.initPool(BORROWER_PID, address(collateral));
        nft.setDiamond(address(diamond));
        nft.setMinter(address(this));
        harness.setConfig(_defaultConfig());
        harness.setTreasuryShare(treasury, 5000);
        harness.setActiveCreditShare(0);

        borrowToken.mint(address(diamond), 1_000_000 ether);
        collateral.mint(address(diamond), 1_000_000 ether);
        borrowToken.mint(lender, 500_000 ether);
        collateral.mint(borrower, 500_000 ether);

        uint256 lenderTokenId = nft.mint(lender, LENDER_PID);
        bytes32 lenderKey = nft.getPositionKey(lenderTokenId);
        harness.seedPosition(LENDER_PID, lenderKey, 200 ether);
        vm.prank(lender);
        borrowToken.approve(address(diamond), type(uint256).max);

        uint256 borrowerTokenId = nft.mint(borrower, BORROWER_PID);
        bytes32 borrowerKey = nft.getPositionKey(borrowerTokenId);
        harness.seedPosition(BORROWER_PID, borrowerKey, 200 ether);
        nft.setMinter(address(diamond));
        vm.startPrank(borrower);
        collateral.approve(address(diamond), type(uint256).max);
        borrowToken.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderTokenId,
            lenderPoolId: LENDER_PID,
            collateralPoolId: BORROWER_PID,
            collateralAsset: address(collateral),
            borrowAsset: address(borrowToken),
            principal: 50 ether,
            aprBps: 1000,
            durationSeconds: 1 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lender);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        vm.prank(borrower);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerTokenId);
        uint256 acceptedAt = block.timestamp;

        vm.warp(DirectTestUtils.dueTimestamp(acceptedAt, params.durationSeconds) + 1 days);
        collateral.setReentrancyTarget(IDirectFacet(address(diamond)), ReenteringERC20.Mode.Recover, 0, 0, agreementId);

        vm.prank(lender);
        lifecycle.recover(agreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        (uint256 lockedBorrower,,) = views.directBalances(borrowerKey, BORROWER_PID);
        (, , uint256 borrowedBorrower) = views.directBalances(borrowerKey, LENDER_PID);
        (, uint256 lentLender,) = views.directBalances(lenderKey, LENDER_PID);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Defaulted), "agreement defaulted");
        assertEq(borrowedBorrower, 0, "borrowed cleared");
        assertEq(lentLender, 0, "lent cleared");
        assertEq(lockedBorrower, 0, "collateral unlocked");
    }
}
