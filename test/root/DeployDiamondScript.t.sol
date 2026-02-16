// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployDiamondScript} from "../../script/DeployDiamond.s.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {EqualIndexViewFacetV3} from "../../src/views/EqualIndexViewFacetV3.sol";
import {ConfigViewFacet} from "../../src/views/ConfigViewFacet.sol";
import {SettlementEscrowFacet} from "../../src/EqualX/SettlementEscrowFacet.sol";
import {PositionAgentViewFacet} from "../../src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {FlashLoanFacet} from "../../src/equallend/FlashLoanFacet.sol";
import {AdminGovernanceFacet} from "../../src/admin/AdminGovernanceFacet.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ModuleGatewayFacet} from "../../src/modules/ModuleGatewayFacet.sol";
import {ModuleViewFacet} from "../../src/modules/ModuleViewFacet.sol";

contract DeployDiamondScriptTest is Test {
    uint256 internal constant DEPLOYER_PK = 0xA11CE;
    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;

    function testRunDeploysAndInitializesFullProtocol() public {
        address owner = vm.addr(DEPLOYER_PK);
        address timelock = address(0xBEEF);
        address treasury = address(0xCAFE);
        address identityRegistry = address(0x8004);
        address entryPoint = address(0x1337);

        vm.deal(owner, 1_000 ether);
        vm.setEnv("OWNER", vm.toString(owner));
        vm.setEnv("TIMELOCK", vm.toString(timelock));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.setEnv("IDENTITY_REGISTRY", vm.toString(identityRegistry));
        vm.setEnv("ENTRYPOINT_ADDRESS", vm.toString(entryPoint));

        DeployDiamondScript script = new DeployDiamondScript();
        script.run();

        address diamond = script.deployedDiamond();
        assertTrue(diamond != address(0), "diamond not deployed");
        assertTrue(script.deployedPositionNFT() != address(0), "position nft not deployed");
        assertTrue(script.deployedOptionToken() != address(0), "option token not deployed");
        assertTrue(script.deployedFuturesToken() != address(0), "futures token not deployed");
        assertTrue(script.deployedMailbox() != address(0), "mailbox not deployed");

        PositionNFT nft = PositionNFT(script.deployedPositionNFT());
        assertEq(nft.minter(), diamond, "nft minter");
        assertEq(nft.diamond(), diamond, "nft diamond");

        assertEq(OptionToken(script.deployedOptionToken()).manager(), diamond, "option manager");
        assertEq(FuturesToken(script.deployedFuturesToken()).manager(), diamond, "futures manager");

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("depositToPosition(uint256,uint256,uint256,uint256)")),
            "deposit selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256,uint256)")),
            "withdraw selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("closePoolPosition(uint256,uint256,uint256)")),
            "close pool selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("openRollingFromPosition(uint256,uint256,uint256,uint256)")),
            "open rolling selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("makePaymentFromPosition(uint256,uint256,uint256,uint256)")),
            "pay rolling selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("closeRollingCreditFromPosition(uint256,uint256,uint256)")),
            "close rolling selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256,uint256,uint256)")),
            "open fixed selector"
        );
        _assertSelectorMapped(
            loupe,
            bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256,uint256,uint256)")),
            "repay fixed selector"
        );
        _assertSelectorMapped(loupe, FlashLoanFacet.previewFlashLoanRepayment.selector, "flash preview selector");
        _assertSelectorMapped(
            loupe,
            AdminGovernanceFacet.setManagedPoolSystemShareBps.selector,
            "managed system share selector"
        );
        _assertSelectorMapped(loupe, AdminGovernanceFacet.setPositionNFT.selector, "set position nft selector");
        _assertSelectorMapped(loupe, AmmAuctionFacet.addLiquidity.selector, "amm add liquidity selector");
        _assertSelectorMapped(
            loupe,
            CommunityAuctionFacet.previewCommunitySwap.selector,
            "community preview swap selector"
        );
        _assertSelectorMapped(loupe, ModuleRegistryFacet.registerModule.selector, "module register selector");
        _assertSelectorMapped(loupe, ModuleRegistryFacet.setModuleAciPaused.selector, "module aci pause selector");
        _assertSelectorMapped(loupe, ModuleGatewayFacet.encumberPosition.selector, "module encumber selector");
        _assertSelectorMapped(loupe, ModuleGatewayFacet.pokeModuleAum.selector, "module poke selector");
        _assertSelectorMapped(loupe, ModuleViewFacet.getModule.selector, "module get selector");
        _assertSelectorMapped(loupe, ModuleViewFacet.getModuleAumState.selector, "module aum state selector");

        SettlementEscrowFacet escrow = SettlementEscrowFacet(diamond);
        assertEq(escrow.refundSafetyWindow(), 3 days, "refund safety window");
        assertEq(escrow.atomicDesk(), diamond, "atomic desk target");
        assertEq(escrow.mailbox(), script.deployedMailbox(), "mailbox wiring");
        assertEq(escrow.governor(), timelock, "escrow governor");
        assertTrue(escrow.committee(timelock), "timelock committee");

        (address registry, address implementation, address idRegistry) =
            PositionAgentViewFacet(diamond).getCanonicalRegistries();
        assertEq(registry, ERC6551_REGISTRY, "erc6551 registry");
        assertTrue(implementation != address(0), "erc6551 implementation");
        assertEq(idRegistry, identityRegistry, "identity registry");

        EqualIndexViewFacetV3 viewFacet = EqualIndexViewFacetV3(diamond);
        EqualIndexViewFacetV3.IndexView memory idx0 = viewFacet.getIndex(0);
        EqualIndexViewFacetV3.IndexView memory idx1 = viewFacet.getIndex(1);
        EqualIndexViewFacetV3.IndexView memory idx2 = viewFacet.getIndex(2);
        assertTrue(idx0.token != address(0), "index0 token");
        assertTrue(idx1.token != address(0), "index1 token");
        assertTrue(idx2.token != address(0), "index2 token");
        assertEq(idx0.assets.length, 2, "index0 assets");
        assertEq(idx1.assets.length, 2, "index1 assets");
        assertEq(idx2.assets.length, 1, "index2 assets");

        (ConfigViewFacet.PoolInfo[] memory pools, uint256 totalPools) = ConfigViewFacet(diamond).getPoolList(0, 20);
        assertTrue(totalPools >= 6, "pool count");
        assertTrue(pools.length >= 6, "pool list length");

        uint256 nativePoolCount;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].underlying == address(0)) {
                nativePoolCount++;
            }
        }
        assertEq(nativePoolCount, 1, "native pool count");
        assertTrue(_containsUnderlying(pools, idx0.token), "index0 pool missing");
        assertTrue(_containsUnderlying(pools, idx1.token), "index1 pool missing");
        assertTrue(_containsUnderlying(pools, idx2.token), "index2 pool missing");

        uint256 repaymentPreview = FlashLoanFacet(diamond).previewFlashLoanRepayment(1, 1 ether);
        assertTrue(repaymentPreview >= 1 ether, "flash repayment preview");
    }

    function _assertSelectorMapped(IDiamondLoupe loupe, bytes4 selector, string memory message) internal {
        assertTrue(loupe.facetAddress(selector) != address(0), message);
    }

    function _containsUnderlying(ConfigViewFacet.PoolInfo[] memory pools, address underlying)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].underlying == underlying) {
                return true;
            }
        }
        return false;
    }
}
