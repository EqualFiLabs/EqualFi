// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PositionAgentAmmSkillModule} from "../src/agent-wallet/erc6900/PositionAgentAmmSkillModule.sol";
import {LibAmmSkillStorage} from "../src/agent-wallet/erc6900/PositionAgentAmmSkillModule.sol";
import {IERC6900Account} from "@agent-wallet-core/interfaces/IERC6900Account.sol";
import {ExecutionManifest} from "@agent-wallet-core/libraries/ModuleTypes.sol";

interface IERC6551Account {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function owner() external view returns (address);
}

contract UpgradeAmmSkillModule is Script {
    address constant DIAMOND = 0x027c9BA58Be0af69C990DA55630d9042D067652b;
    address constant OLD_MODULE = 0x402DfcF43f1e9a7101717A97322bfA621c6a7a47;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Optional: TBA to upgrade (set via env or leave address(0) to skip)
        address tbaToUpgrade = vm.envOr("TBA_ADDRESS", address(0));
        
        console2.log("Broadcaster:", deployer);
        console2.log("Old module:", OLD_MODULE);
        console2.log("Diamond:", DIAMOND);
        if (tbaToUpgrade != address(0)) {
            console2.log("TBA to upgrade:", tbaToUpgrade);
        }
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy new module
        PositionAgentAmmSkillModule newModule = new PositionAgentAmmSkillModule();
        console2.log("New PositionAgentAmmSkillModule deployed at:", address(newModule));
        
        // If TBA provided, install new module and configure
        if (tbaToUpgrade != address(0)) {
            _upgradeTBA(tbaToUpgrade, address(newModule), deployer);
        }
        
        vm.stopBroadcast();
        
        console2.log("");
        console2.log("=== NEXT STEPS ===");
        console2.log("1. Update equalfi-amm skill with new module address:", address(newModule));
        console2.log("2. For each TBA, run this script with TBA_ADDRESS=<tba>");
        console2.log("3. Update session key policies if needed for new selectors");
    }
    
    function _upgradeTBA(address tba, address newModule, address owner) internal {
        // Verify ownership
        address tbaOwner = IERC6551Account(tba).owner();
        require(tbaOwner == owner, "Not TBA owner");
        
        // Get execution manifest from new module
        ExecutionManifest memory manifest = PositionAgentAmmSkillModule(newModule).executionManifest();
        
        // Install new execution module
        bytes memory installData = ""; // Module's onInstall accepts empty bytes
        
        IERC6900Account(tba).installExecution(newModule, manifest, installData);
        console2.log("Installed new execution module on TBA");
        
        // Configure via TBA.execute() calls
        // These go through the TBA which calls the module functions
        
        // Set diamond address
        bytes memory setDiamondData = abi.encodeCall(PositionAgentAmmSkillModule.setDiamond, (DIAMOND));
        IERC6900Account(tba).execute(newModule, 0, setDiamondData);
        console2.log("Set diamond address via TBA");
        
        // Configure auction policy
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
            maxFeeBps: 10000,
            minReserveA: 0,
            maxReserveA: 0,
            minReserveB: 0,
            maxReserveB: 0
        });
        
        bytes memory setPolicyData = abi.encodeCall(PositionAgentAmmSkillModule.setAuctionPolicy, (policy));
        IERC6900Account(tba).execute(newModule, 0, setPolicyData);
        console2.log("Configured auction policy via TBA");
        
        // Configure roll policy
        LibAmmSkillStorage.RollPolicy memory rollPolicy = LibAmmSkillStorage.RollPolicy({
            enabled: true,
            enforcePoolAllowlist: false
        });
        
        bytes memory setRollData = abi.encodeCall(PositionAgentAmmSkillModule.setRollPolicy, (rollPolicy));
        IERC6900Account(tba).execute(newModule, 0, setRollData);
        console2.log("Configured roll policy via TBA");
        
        console2.log("TBA upgrade complete!");
    }
}
