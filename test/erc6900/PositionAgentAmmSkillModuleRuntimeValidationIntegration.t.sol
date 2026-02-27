// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {BeaconProxy} from "@agent-wallet-core/core/BeaconProxy.sol";
import {MockBeacon} from "../helpers/MockBeacon.sol";
import {ExecutionManifest} from "@agent-wallet-core/libraries/ModuleTypes.sol";
import {IERC6900Account} from "@agent-wallet-core/interfaces/IERC6900Account.sol";
import {NFTBoundMSCA} from "@agent-wallet-core/core/NFTBoundMSCA.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {PositionMSCAImpl} from "../../src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {PositionAgentAmmSkillModule, LibAmmSkillStorage} from "../../src/agent-wallet/erc6900/PositionAgentAmmSkillModule.sol";

contract MockPositionNFT is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Position", "PNFT") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextId++;
        _mint(to, tokenId);
    }
}

contract MockERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address account) {
        assembly {
            pop(chainId)
            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            let computed := keccak256(0x00, 0x55)

            if iszero(extcodesize(computed)) {
                let deployed := create2(0, 0x55, 0xb7, salt)
                if iszero(deployed) {
                    mstore(0x00, 0x20188a59)
                    revert(0x1c, 0x04)
                }
                mstore(0x6c, deployed)
                return(0x6c, 0x20)
            }

            mstore(0x00, shr(96, shl(96, computed)))
            return(0x00, 0x20)
        }
    }
}

contract MockAmmDiamond {
    uint256 public nextAuctionId;
    uint256 public lastMakerPositionId;

    mapping(uint256 => DerivativeTypes.AmmAuction) internal _auctions;

    function createAuction(DerivativeTypes.CreateAuctionParams calldata params) external returns (uint256 auctionId) {
        auctionId = ++nextAuctionId;
        lastMakerPositionId = params.positionId;
        DerivativeTypes.AmmAuction storage a = _auctions[auctionId];
        a.makerPositionId = params.positionId;
        a.active = true;
    }

    function getAuction(uint256 auctionId) external view returns (DerivativeTypes.AmmAuction memory) {
        return _auctions[auctionId];
    }

    function cancelAuction(uint256 auctionId) external {
        _auctions[auctionId].active = false;
    }
}

contract PositionAgentAmmSkillModuleRuntimeValidationIntegrationTest is Test {
    bytes32 private constant SALT = bytes32(0);

    address internal owner = address(0xA11CE);
    address internal attacker = address(0xB0B);

    MockPositionNFT internal nft;
    MockERC6551Registry internal registry;
    PositionMSCAImpl internal implementation;
    MockBeacon internal beacon;
    BeaconProxy internal beaconProxy;
    PositionAgentAmmSkillModule internal module;
    MockAmmDiamond internal diamond;

    address internal account;
    uint256 internal tokenId;

    function setUp() public {
        nft = new MockPositionNFT();
        registry = new MockERC6551Registry();
        implementation = new PositionMSCAImpl(address(0x1234));
        beacon = new MockBeacon(address(implementation));
        beaconProxy = new BeaconProxy(address(beacon));
        module = new PositionAgentAmmSkillModule();
        diamond = new MockAmmDiamond();

        tokenId = nft.mint(owner);
        account = registry.createAccount(address(beaconProxy), SALT, block.chainid, address(nft), tokenId);

        ExecutionManifest memory manifest = module.executionManifest();
        vm.prank(owner);
        IERC6900Account(account).installExecution(address(module), manifest, "");

        vm.prank(owner);
        PositionAgentAmmSkillModule(account).setDiamond(address(diamond));

        LibAmmSkillStorage.AuctionPolicy memory policy = LibAmmSkillStorage.AuctionPolicy({
            enabled: true,
            allowCancel: true,
            allowFinalize: true,
            allowAddLiquidity: true,
            allowCommunityJoin: true,
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
        vm.prank(owner);
        PositionAgentAmmSkillModule(account).setAuctionPolicy(policy);
    }

    function test_runtimeValidation_nonOwnerCannotExecuteInstalledAmmSelector() public {
        DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
            positionId: tokenId,
            poolIdA: 1,
            poolIdB: 2,
            reserveA: 1 ether,
            reserveB: 2 ether,
            startTime: 10,
            endTime: 100,
            feeBps: 30,
            feeAsset: DerivativeTypes.FeeAsset.TokenIn,
            invariantMode: DerivativeTypes.InvariantMode.Volatile
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NFTBoundMSCA.UnauthorizedCaller.selector, attacker));
        PositionAgentAmmSkillModule(account).createAuction(params);

        vm.prank(owner);
        uint256 auctionId = PositionAgentAmmSkillModule(account).createAuction(params);
        assertEq(auctionId, 1, "owner call should succeed");
        assertEq(diamond.lastMakerPositionId(), tokenId, "auction should be forwarded to AMM diamond");
    }
}
