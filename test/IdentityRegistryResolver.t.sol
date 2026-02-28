// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployDiamondScript} from "../script/DeployDiamond.s.sol";
import {LeanDeployScript} from "../script/leanDeploy.s.sol";

contract DeployDiamondResolverHarness is DeployDiamondScript {
    function resolveIdentityRegistry() external view returns (address) {
        return _resolveIdentityRegistry();
    }

    function chainEnvKey() external view returns (string memory) {
        return string.concat("IDENTITY_REGISTRY_", vm.toString(block.chainid));
    }
}

contract LeanDeployResolverHarness is LeanDeployScript {
    function resolveIdentityRegistry() external view returns (address) {
        return _resolveIdentityRegistry();
    }

    function chainEnvKey() external view returns (string memory) {
        return string.concat("IDENTITY_REGISTRY_", vm.toString(block.chainid));
    }
}

contract IdentityRegistryResolverTest is Test {
    address internal constant ERC8004_MAINNET = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant ERC8004_TESTNET = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function setUp() public {
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY_1", address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY_8453", address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY_11155111", address(0));
    }

    function testDeployDiamondIdentityRegistryChainOverridePrecedence() public {
        vm.chainId(84_53);
        DeployDiamondResolverHarness harness = new DeployDiamondResolverHarness();
        _setIdentityRegistryOverride(harness.chainEnvKey(), address(0xBEEF));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0xCAFE));
        assertEq(harness.resolveIdentityRegistry(), address(0xBEEF), "chain override should win");
    }

    function testDeployDiamondIdentityRegistryGlobalOverrideFallback() public {
        vm.chainId(84_53);
        DeployDiamondResolverHarness harness = new DeployDiamondResolverHarness();
        _setIdentityRegistryOverride(harness.chainEnvKey(), address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0xCAFE));
        assertEq(harness.resolveIdentityRegistry(), address(0xCAFE), "global override should apply");
    }

    function testDeployDiamondIdentityRegistryMainnetDefault() public {
        vm.chainId(1);
        DeployDiamondResolverHarness harness = new DeployDiamondResolverHarness();
        _setIdentityRegistryOverride(harness.chainEnvKey(), address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0));
        assertEq(harness.resolveIdentityRegistry(), ERC8004_MAINNET, "mainnet default mismatch");
    }

    function testLeanDeployIdentityRegistryChainOverridePrecedence() public {
        vm.chainId(84_53);
        LeanDeployResolverHarness harness = new LeanDeployResolverHarness();
        _setIdentityRegistryOverride(harness.chainEnvKey(), address(0xBEEF));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0xCAFE));
        assertEq(harness.resolveIdentityRegistry(), address(0xBEEF), "chain override should win");
    }

    function testLeanDeployIdentityRegistryGlobalOverrideFallback() public {
        vm.chainId(84_53);
        LeanDeployResolverHarness harness = new LeanDeployResolverHarness();
        _setIdentityRegistryOverride(harness.chainEnvKey(), address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0xCAFE));
        assertEq(harness.resolveIdentityRegistry(), address(0xCAFE), "global override should apply");
    }

    function testLeanDeployIdentityRegistrySepoliaDefault() public {
        vm.chainId(11_155_111);
        LeanDeployResolverHarness harness = new LeanDeployResolverHarness();
        _setIdentityRegistryOverride(harness.chainEnvKey(), address(0));
        _setIdentityRegistryOverride("IDENTITY_REGISTRY", address(0));
        assertEq(harness.resolveIdentityRegistry(), ERC8004_TESTNET, "sepolia default mismatch");
    }

    function _setIdentityRegistryOverride(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
    }
}
