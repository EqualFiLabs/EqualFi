// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LeanDeployScript} from "../../script/leanDeploy.s.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";

// Define local interfaces
interface IPositionManagement {
    function mintPosition(uint256 pid) external payable returns (uint256 tokenId);
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external payable returns (uint256 tokenId);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external payable;
}

interface IPositionNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionKey(uint256 tokenId) external view returns (bytes32);
}

interface IDirectLendingFacet {
    function postOffer(DirectTypes.DirectOfferParams calldata params) external returns (uint256 offerId);
    function cancelOffer(uint256 offerId) external;
}

interface IMamCreationFacet {
    function createCurve(MamTypes.CurveDescriptor calldata desc) external returns (uint256 curveId);
    function cancelCurve(uint256 curveId) external;
}

interface IAmmAuctionFacet {
    function createAuction(DerivativeTypes.CreateAuctionParams calldata params) external returns (uint256 auctionId);
    function swapExactInOrFinalize(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 amountOut, bool finalized);
    function cancelAuction(uint256 auctionId) external;
}

contract PositionLifeCycleTest is Test {
    
    LeanDeployScript.Deployment internal sys;
    address internal rETH; // Pool 1
    address internal USDC; // Pool 5
    uint256 internal posId;
    address internal user;
    uint256 internal activeOfferId;
    uint256 internal activeCurveId;
    uint256 internal activeAmmId;

    function setUp() public {
        LeanDeployScript script = new LeanDeployScript();
        user = address(0x1337);
        
        sys = script.deployForTest(address(this), address(this), address(this));
        
        rETH = sys.tokens[0]; // Pool 1
        USDC = sys.tokens[4]; // Pool 5
        
        MockERC20(rETH).mint(user, 1_000_000 ether);
        MockERC20(USDC).mint(user, 1_000_000 * 1e6);
    }

    function testLifeCycle() public {
        vm.startPrank(user);
        
        _initUser();
        _stepDirectLending();
        _stepMamBid();
        _stepAmmAuction(); // Create & Swap
        
        _stepUnwind();
        
        vm.stopPrank();
    }

    function _initUser() internal {
        MockERC20(rETH).approve(sys.diamond, type(uint256).max);
        MockERC20(USDC).approve(sys.diamond, type(uint256).max);
        
        posId = IPositionManagement(sys.diamond).mintPositionWithDeposit(1, 100 ether);
        
        // Deposit USDC for MAM/AMM
        // Need enough for MAM (3000 * 5 = 15000) + AMM (30000)
        // Let's deposit 100,000 USDC
        IPositionManagement(sys.diamond).depositToPosition(posId, 5, 100_000 * 1e6);
    }

    function _stepDirectLending() internal {
        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: posId,
            lenderPoolId: 1, // rETH
            collateralPoolId: 1, 
            collateralAsset: rETH,
            borrowAsset: rETH,
            principal: 10 ether,
            aprBps: 500,
            durationSeconds: 30 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        activeOfferId = IDirectLendingFacet(sys.diamond).postOffer(params);
        assertTrue(activeOfferId > 0, "Direct Offer ID > 0");
    }

    function _stepMamBid() internal {
        bytes32 key = IPositionNFT(sys.positionNFT).getPositionKey(posId);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: key,
            makerPositionId: posId,
            poolIdA: 1,
            poolIdB: 5,
            tokenA: rETH,
            tokenB: USDC,
            side: false, // Sell A
            priceIsQuotePerBase: true,
            maxVolume: 5 ether,
            startPrice: 3000 * 1e6, 
            endPrice: 3000 * 1e6,   
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 10,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 0
        });

        activeCurveId = IMamCreationFacet(sys.diamond).createCurve(desc);
        assertTrue(activeCurveId > 0, "MAM Curve ID > 0");
    }

    function _stepAmmAuction() internal {
        // Create AMM: 10 rETH + 30000 USDC (Price 3000)
        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: posId,
            poolIdA: 1,
            poolIdB: 5,
            reserveA: 10 ether,
            reserveB: 30000 * 1e6,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30, // 0.3%
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });

        activeAmmId = IAmmAuctionFacet(sys.diamond).createAuction(params);
        assertTrue(activeAmmId > 0, "AMM Auction ID > 0");

        // Swap against it (Take side)
        // User (0x1337) is swapping, not the Position NFT
        // Swap 1 rETH -> Expect ~3000 USDC (ignoring fee/slippage for simple check)
        uint256 amountIn = 1 ether;
        
        (uint256 amountOut, ) = IAmmAuctionFacet(sys.diamond).swapExactInOrFinalize(
            activeAmmId,
            rETH,
            amountIn,
            0, // Min out (slippage)
            user
        );
        assertTrue(amountOut > 0, "Swap output > 0");
    }

    function _stepUnwind() internal {
        IDirectLendingFacet(sys.diamond).cancelOffer(activeOfferId);
        IMamCreationFacet(sys.diamond).cancelCurve(activeCurveId);
        IAmmAuctionFacet(sys.diamond).cancelAuction(activeAmmId);
    }
}
