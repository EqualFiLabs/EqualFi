// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {AdminGovernanceFacet} from "../src/admin/AdminGovernanceFacet.sol";
import {PoolManagementFacet} from "../src/equallend/PoolManagementFacet.sol";
import {ConfigViewFacet} from "../src/views/ConfigViewFacet.sol";
import {PenaltyFacet} from "../src/equallend/PenaltyFacet.sol";
import {EqualIndexPositionFacet} from "../src/equalindex/EqualIndexPositionFacet.sol";
import {FlashLoanFacet} from "../src/equallend/FlashLoanFacet.sol";
import {PositionManagementFacet} from "../src/equallend/PositionManagementFacet.sol";
import {LendingFacet} from "../src/equallend/LendingFacet.sol";
import {OptionsFacet} from "../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../src/derivatives/FuturesFacet.sol";
import {Types} from "../src/libraries/Types.sol";

interface IOwnershipFacet {
    function owner() external view returns (address);
}

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

interface IPoolManagementFacetInitConfig {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

contract UpgradeManagedPoolSystemShare is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        address diamondOwner = IOwnershipFacet(diamond).owner();

        console2.log("Chain ID:", block.chainid);
        console2.log("Diamond:", diamond);
        console2.log("Sender:", sender);
        console2.log("Diamond owner:", diamondOwner);
        require(sender == diamondOwner, "Upgrade: sender is not diamond owner");

        vm.startBroadcast(pk);

        AdminGovernanceFacet admin = new AdminGovernanceFacet();
        PoolManagementFacet poolManagement = new PoolManagementFacet();
        ConfigViewFacet configView = new ConfigViewFacet();
        PenaltyFacet penalty = new PenaltyFacet();
        EqualIndexPositionFacet equalIndexPosition = new EqualIndexPositionFacet();
        FlashLoanFacet flashLoan = new FlashLoanFacet();
        PositionManagementFacet positionManagement = new PositionManagementFacet();
        LendingFacet lending = new LendingFacet();
        OptionsFacet optionsFacet = new OptionsFacet();
        FuturesFacet futuresFacet = new FuturesFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](20);
        uint256 i;

        i = _appendCuts(cuts, i, diamond, address(admin), _selectors(admin));
        i = _appendCuts(cuts, i, diamond, address(configView), _selectors(configView));
        i = _appendCuts(cuts, i, diamond, address(poolManagement), _selectors(poolManagement));
        i = _appendCuts(cuts, i, diamond, address(penalty), _selectors(penalty));
        i = _appendCuts(cuts, i, diamond, address(equalIndexPosition), _selectors(equalIndexPosition));
        i = _appendCuts(cuts, i, diamond, address(flashLoan), _selectors(flashLoan));
        i = _appendCuts(cuts, i, diamond, address(positionManagement), _selectors(positionManagement));
        i = _appendCuts(cuts, i, diamond, address(lending), _selectors(lending));
        i = _appendCuts(cuts, i, diamond, address(optionsFacet), _selectors(optionsFacet));
        i = _appendCuts(cuts, i, diamond, address(futuresFacet), _selectors(futuresFacet));

        assembly {
            mstore(cuts, i)
        }

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        console2.log("Upgrade complete for ManagedPoolSystemShare facets");
        console2.log("Diamond:", diamond);

        vm.stopBroadcast();
    }

    function _cut(address facet, bytes4[] memory selectors, IDiamondCut.FacetCutAction action)
        internal
        pure
        returns (IDiamondCut.FacetCut memory c)
    {
        c.facetAddress = facet;
        c.action = action;
        c.functionSelectors = selectors;
    }

    function _selectors(AdminGovernanceFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = AdminGovernanceFacet.setDefaultPoolConfig.selector;
        s[1] = AdminGovernanceFacet.setAumFee.selector;
        s[2] = AdminGovernanceFacet.setPoolConfig.selector;
        s[3] = AdminGovernanceFacet.setRollingDelinquencyThresholds.selector;
        s[4] = AdminGovernanceFacet.setRollingMinPaymentBps.selector;
        s[5] = AdminGovernanceFacet.setPoolDeprecated.selector;
        s[6] = AdminGovernanceFacet.setFoundationReceiver.selector;
        s[7] = AdminGovernanceFacet.setDefaultMaintenanceRateBps.selector;
        s[8] = AdminGovernanceFacet.setMaxMaintenanceRateBps.selector;
        s[9] = AdminGovernanceFacet.setTreasury.selector;
        s[10] = AdminGovernanceFacet.setTreasuryShareBps.selector;
        s[11] = AdminGovernanceFacet.setActiveCreditShareBps.selector;
        s[12] = AdminGovernanceFacet.setActionFeeBounds.selector;
        s[13] = AdminGovernanceFacet.setActionFeeConfig.selector;
        s[14] = AdminGovernanceFacet.setDerivativeFeeConfig.selector;
        s[15] = AdminGovernanceFacet.setProtocolFeeReceiver.selector;
        s[16] = AdminGovernanceFacet.setIndexCreationFee.selector;
        s[17] = AdminGovernanceFacet.setPoolCreationFee.selector;
        s[18] = AdminGovernanceFacet.setPositionMintFee.selector;
        s[19] = AdminGovernanceFacet.executeDiamondCut.selector;
        s[20] = AdminGovernanceFacet.setDirectRollingConfig.selector;
    }

    function _selectors(PoolManagementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
        s[0] = IPoolManagementFacetInitDefault.initPool.selector;
        s[1] = IPoolManagementFacetInitConfig.initPool.selector;
        s[2] = PoolManagementFacet.initPoolWithActionFees.selector;
        s[3] = PoolManagementFacet.initManagedPool.selector;
        s[4] = PoolManagementFacet.setRollingApy.selector;
        s[5] = PoolManagementFacet.setDepositorLTV.selector;
        s[6] = PoolManagementFacet.setMinDepositAmount.selector;
        s[7] = PoolManagementFacet.setMinLoanAmount.selector;
        s[8] = PoolManagementFacet.setMinTopupAmount.selector;
        s[9] = PoolManagementFacet.setDepositCap.selector;
        s[10] = PoolManagementFacet.setIsCapped.selector;
        s[11] = PoolManagementFacet.setMaxUserCount.selector;
        s[12] = PoolManagementFacet.setMaintenanceRate.selector;
        s[13] = PoolManagementFacet.setFlashLoanFee.selector;
        s[14] = PoolManagementFacet.setActionFees.selector;
        s[15] = PoolManagementFacet.addToWhitelist.selector;
        s[16] = PoolManagementFacet.removeFromWhitelist.selector;
        s[17] = PoolManagementFacet.setWhitelistEnabled.selector;
        s[18] = PoolManagementFacet.transferManager.selector;
        s[19] = PoolManagementFacet.renounceManager.selector;
    }

    function _selectors(ConfigViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectors(PenaltyFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("penalizePositionRolling(uint256,uint256,address)"));
        s[1] = bytes4(keccak256("penalizePositionRolling(uint256,address)"));
        s[2] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,uint256,address)"));
        s[3] = bytes4(keccak256("penalizePositionFixed(uint256,uint256,address)"));
    }

    function _selectors(EqualIndexPositionFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualIndexPositionFacet.mintFromPosition.selector;
        s[1] = EqualIndexPositionFacet.burnFromPosition.selector;
    }

    function _selectors(FlashLoanFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = FlashLoanFacet.flashLoan.selector;
    }

    function _selectors(PositionManagementFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = PositionManagementFacet.mintPosition.selector;
        s[1] = PositionManagementFacet.mintPositionWithDeposit.selector;
        s[2] = bytes4(keccak256("depositToPosition(uint256,uint256,uint256)"));
        s[3] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256)"));
        s[4] = bytes4(keccak256("rollYieldToPosition(uint256,uint256)"));
        s[5] = bytes4(keccak256("closePoolPosition(uint256,uint256)"));
        s[6] = PositionManagementFacet.cleanupMembership.selector;
    }

    function _selectors(LendingFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = bytes4(keccak256("openRollingFromPosition(uint256,uint256,uint256)"));
        s[1] = bytes4(keccak256("openRollingFromPosition(uint256,uint256)"));
        s[2] = bytes4(keccak256("makePaymentFromPosition(uint256,uint256,uint256)"));
        s[3] = bytes4(keccak256("makePaymentFromPosition(uint256,uint256)"));
        s[4] = bytes4(keccak256("expandRollingFromPosition(uint256,uint256,uint256)"));
        s[5] = bytes4(keccak256("expandRollingFromPosition(uint256,uint256)"));
        s[6] = bytes4(keccak256("closeRollingCreditFromPosition(uint256,uint256)"));
        s[7] = bytes4(keccak256("closeRollingCreditFromPosition(uint256)"));
        s[8] = bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256,uint256)"));
        s[9] = bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256)"));
        s[10] = bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256,uint256)"));
        s[11] = bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256)"));
    }

    function _selectors(OptionsFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = OptionsFacet.setOptionToken.selector;
        s[1] = OptionsFacet.setOptionsPaused.selector;
        s[2] = OptionsFacet.createOptionSeries.selector;
        s[3] = OptionsFacet.exerciseOptions.selector;
        s[4] = OptionsFacet.exerciseOptionsFor.selector;
        s[5] = OptionsFacet.reclaimOptions.selector;
    }

    function _selectors(FuturesFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = FuturesFacet.setFuturesToken.selector;
        s[1] = FuturesFacet.setFuturesPaused.selector;
        s[2] = FuturesFacet.createFuturesSeries.selector;
        s[3] = FuturesFacet.settleFutures.selector;
        s[4] = FuturesFacet.settleFuturesFor.selector;
        s[5] = FuturesFacet.reclaimFutures.selector;
    }

    function _appendCuts(
        IDiamondCut.FacetCut[] memory cuts,
        uint256 idx,
        address diamond,
        address facet,
        bytes4[] memory selectors
    ) internal view returns (uint256 newIdx) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        uint256 addCount;
        uint256 replaceCount;
        for (uint256 j; j < selectors.length; j++) {
            bytes4 sel = selectors[j];
            address existing = loupe.facetAddress(sel);
            if (existing == address(0)) {
                addCount++;
            } else if (existing != facet) {
                replaceCount++;
            }
        }

        if (replaceCount > 0) {
            bytes4[] memory replaceSelectors = new bytes4[](replaceCount);
            uint256 r;
            for (uint256 j; j < selectors.length; j++) {
                bytes4 sel = selectors[j];
                address existing = loupe.facetAddress(sel);
                if (existing != address(0) && existing != facet) {
                    replaceSelectors[r++] = sel;
                }
            }
            cuts[idx++] = _cut(facet, replaceSelectors, IDiamondCut.FacetCutAction.Replace);
        }

        if (addCount > 0) {
            bytes4[] memory addSelectors = new bytes4[](addCount);
            uint256 a;
            for (uint256 j; j < selectors.length; j++) {
                bytes4 sel = selectors[j];
                address existing = loupe.facetAddress(sel);
                if (existing == address(0)) {
                    addSelectors[a++] = sel;
                }
            }
            cuts[idx++] = _cut(facet, addSelectors, IDiamondCut.FacetCutAction.Add);
        }

        return idx;
    }
}
