// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {PositionAgentAmmSkillModule, LibAmmSkillStorage, IAmmAuctionFacet, IPositionManagementFacet} from "../../src/erc6900/PositionAgentAmmSkillModule.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551Account.sol";

/// @notice Unit tests for PositionAgentAmmSkillModule tokenId binding (one agent per NFT)
contract PositionAgentAmmSkillModuleTest is Test {
    // custom error selectors (cheaper + decouples from type name visibility)
    bytes4 internal constant POSITION_ID_MISMATCH = bytes4(keccak256("AmmSkill_PositionIdMismatch(uint256,uint256)"));
    bytes4 internal constant AUCTION_NOT_FOR_THIS_POSITION =
        bytes4(keccak256("AmmSkill_AuctionNotForThisPosition(uint256,uint256,uint256)"));

    address internal owner = address(0xA11CE);

    PositionAgentAmmSkillModule internal module;
    MockDiamond internal diamond;
    Mock6551Account internal account;

    function setUp() public {
        module = new PositionAgentAmmSkillModule();
        diamond = new MockDiamond();
        account = new Mock6551Account(address(module), owner, 1);

        // configure module storage (via delegatecall through account)
        vm.startPrank(owner);

        PositionAgentAmmSkillModule(address(account)).setDiamond(address(diamond));

        LibAmmSkillStorage.AuctionPolicy memory auctionPolicy = LibAmmSkillStorage.AuctionPolicy({
            enabled: true,
            allowCancel: true,
            enforcePoolAllowlist: false,
            minDuration: 0,
            maxDuration: 0,
            minFeeBps: 0,
            maxFeeBps: 0,
            minReserveA: 0,
            maxReserveA: 0,
            minReserveB: 0,
            maxReserveB: 0
        });
        PositionAgentAmmSkillModule(address(account)).setAuctionPolicy(auctionPolicy);

        LibAmmSkillStorage.RollPolicy memory rollPolicy = LibAmmSkillStorage.RollPolicy({
            enabled: true,
            enforcePoolAllowlist: false
        });
        PositionAgentAmmSkillModule(address(account)).setRollPolicy(rollPolicy);

        vm.stopPrank();
    }

    function test_createAuction_revertsWhenPositionIdDoesNotMatchBoundTokenId() public {
        DerivativeTypes.CreateAuctionParams memory params = _defaultAuctionParams();
        params.positionId = 2; // mismatch; bound tokenId = 1

        vm.expectRevert(abi.encodeWithSelector(POSITION_ID_MISMATCH, uint256(1), uint256(2)));
        PositionAgentAmmSkillModule(address(account)).createAuction(params);
    }

    function test_createAuction_forwardsWhenPositionIdMatchesBoundTokenId() public {
        DerivativeTypes.CreateAuctionParams memory params = _defaultAuctionParams();
        params.positionId = 1;

        uint256 auctionId = PositionAgentAmmSkillModule(address(account)).createAuction(params);
        assertEq(auctionId, 1);

        // Verify forwarded params reached the diamond mock
        assertEq(diamond.lastCreateParams().positionId, 1);
        assertEq(diamond.lastCreateParams().poolIdA, params.poolIdA);
        assertEq(diamond.lastCreateParams().poolIdB, params.poolIdB);
        assertEq(diamond.lastCreateParams().reserveA, params.reserveA);
        assertEq(diamond.lastCreateParams().reserveB, params.reserveB);
        assertEq(uint256(diamond.lastCreateParams().feeAsset), uint256(params.feeAsset));
    }

    function test_rollYield_revertsWhenTokenIdDoesNotMatchBoundTokenId() public {
        vm.expectRevert(abi.encodeWithSelector(POSITION_ID_MISMATCH, uint256(1), uint256(2)));
        PositionAgentAmmSkillModule(address(account)).rollYieldToPosition(2, 123);
    }

    function test_rollYield_forwardsWhenTokenIdMatchesBoundTokenId() public {
        PositionAgentAmmSkillModule(address(account)).rollYieldToPosition(1, 777);
        assertEq(diamond.lastRollTokenId(), 1);
        assertEq(diamond.lastRollPid(), 777);
    }

    function test_cancelAuction_revertsWhenAuctionMakerPositionIdDoesNotMatchBoundTokenId() public {
        // create an auction for a different maker position id
        uint256 otherAuctionId = diamond.seedAuctionWithMakerPositionId(2);

        vm.expectRevert(abi.encodeWithSelector(AUCTION_NOT_FOR_THIS_POSITION, otherAuctionId, uint256(1), uint256(2)));
        PositionAgentAmmSkillModule(address(account)).cancelAuction(otherAuctionId);
    }

    function test_cancelAuction_forwardsWhenAuctionMakerPositionIdMatchesBoundTokenId() public {
        uint256 auctionId = diamond.seedAuctionWithMakerPositionId(1);

        PositionAgentAmmSkillModule(address(account)).cancelAuction(auctionId);

        assertEq(diamond.lastCancelledAuctionId(), auctionId);
        assertTrue(diamond.cancelled());
    }

    function _defaultAuctionParams() internal view returns (DerivativeTypes.CreateAuctionParams memory) {
        return DerivativeTypes.CreateAuctionParams({
            positionId: 1,
            poolIdA: 11,
            poolIdB: 22,
            reserveA: 1e18,
            reserveB: 2e18,
            startTime: 100,
            endTime: 200,
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn
        });
    }
}

/// @notice Minimal ERC-6551 account mock used to provide `token()` + `owner()` context.
/// Calls are routed to the module via delegatecall in fallback.
contract Mock6551Account is IERC6551Account {
    address public immutable module;
    address internal _owner;
    uint256 internal _tokenId;

    constructor(address module_, address owner_, uint256 tokenId_) {
        module = module_;
        _owner = owner_;
        _tokenId = tokenId_;
    }

    receive() external payable {}

    fallback() external payable {
        (bool ok, bytes memory ret) = module.delegatecall(msg.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }

    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        return (block.chainid, address(0xBEEF), _tokenId);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function nonce() external pure returns (uint256) {
        return 0;
    }

    function isValidSigner(address, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xffffffff);
    }
}

/// @notice Minimal diamond mock that the skill module forwards to.
contract MockDiamond {
    uint256 public nextAuctionId;
    bool public cancelled;
    uint256 public lastCancelledAuctionId;
    uint256 public lastRollTokenId;
    uint256 public lastRollPid;

    DerivativeTypes.CreateAuctionParams internal _lastCreateParams;
    mapping(uint256 => DerivativeTypes.AmmAuction) internal _auctions;

    function lastCreateParams() external view returns (DerivativeTypes.CreateAuctionParams memory) {
        return _lastCreateParams;
    }

    function createAuction(DerivativeTypes.CreateAuctionParams calldata params) external returns (uint256 auctionId) {
        _lastCreateParams = params;
        auctionId = ++nextAuctionId;
        DerivativeTypes.AmmAuction storage a = _auctions[auctionId];
        a.makerPositionId = params.positionId;
        a.active = true;
        a.finalized = false;
    }

    function getAuction(uint256 auctionId) external view returns (DerivativeTypes.AmmAuction memory) {
        return _auctions[auctionId];
    }

    function cancelAuction(uint256 auctionId) external {
        cancelled = true;
        lastCancelledAuctionId = auctionId;
        _auctions[auctionId].active = false;
    }

    function rollYieldToPosition(uint256 tokenId, uint256 pid) external {
        lastRollTokenId = tokenId;
        lastRollPid = pid;
    }

    function seedAuctionWithMakerPositionId(uint256 makerPositionId) external returns (uint256 auctionId) {
        auctionId = ++nextAuctionId;
        DerivativeTypes.AmmAuction storage a = _auctions[auctionId];
        a.makerPositionId = makerPositionId;
        a.active = true;
        a.finalized = false;
    }
}
