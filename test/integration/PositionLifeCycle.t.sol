// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LeanDeployScript} from "../../script/leanDeploy.s.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";

// Define local interfaces
interface IPositionManagement {
    function mintPosition(uint256 pid) external payable returns (uint256 tokenId);
    function mintPositionWithDeposit(uint256 pid, uint256 amount) external payable returns (uint256 tokenId);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external payable;
}

interface IPositionNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IDirectLendingFacet {
    function postOffer(DirectTypes.DirectOfferParams calldata params) external returns (uint256 offerId);
}

contract PositionLifeCycleTest is Test {
    
    LeanDeployScript.Deployment internal sys;
    address internal rETH; // Pool 1
    uint256 internal posId;
    address internal user;

    function setUp() public {
        LeanDeployScript script = new LeanDeployScript();
        user = address(0x1337);
        
        sys = script.deployForTest(address(this), address(this), address(this));
        
        rETH = sys.tokens[0];
        
        MockERC20(rETH).mint(user, 1_000_000 ether);
    }

    function testLifeCycle() public {
        vm.startPrank(user);
        
        _initUser();
        // Deposit is handled in minting or separate step
        _stepDirectLending();
        
        vm.stopPrank();
    }

    function _initUser() internal {
        // Mint Position via Diamond (PositionManagementFacet)
        // Mint with deposit to save a step
        
        MockERC20(rETH).approve(sys.diamond, type(uint256).max);
        
        // Pool 1 = rETH
        posId = IPositionManagement(sys.diamond).mintPositionWithDeposit(1, 100 ether);
        
        assertEq(IPositionNFT(sys.positionNFT).ownerOf(posId), user);
    }

    function _stepDirectLending() internal {
        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: posId,
            lenderPoolId: 1, // rETH Pool
            collateralPoolId: 1, // Self-secured
            collateralAsset: rETH,
            borrowAsset: rETH,
            principal: 10 ether,
            aprBps: 500,
            durationSeconds: 30 days,
            collateralLockAmount: 10 ether, // Must be > 0
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        uint256 offerId = IDirectLendingFacet(sys.diamond).postOffer(params);
        assertTrue(offerId > 0, "Offer ID should be > 0");
    }
}
