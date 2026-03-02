// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMIsolatedFacet} from "../../src/ilm-isolated/facets/ILMIsolatedFacet.sol";
import {ILMIsolatedLiquidationFacet} from "../../src/ilm-isolated/facets/ILMIsolatedLiquidationFacet.sol";
import {ILMIsolatedViewFacet} from "../../src/ilm-isolated/facets/ILMIsolatedViewFacet.sol";
import {IIlmIsolatedOracleAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedOracleAdapter.sol";
import {IlmManagedFixedRateIrm} from "../../src/ilm-isolated/irm/IlmManagedFixedRateIrm.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {RollingError_RecoveryNotEligible} from "../../src/libraries/Errors.sol";
import {DirectAmmRollingLoopIntegrationTest} from "./DirectAmmRollingLoopIntegration.t.sol";

interface IPositionManagementExtended {
    function mintPositionWithDeposit(uint256 pid, uint256 amount, uint256 maxAmount, uint256 maxFee)
        external
        returns (uint256 tokenId);
    function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount, uint256 maxAmount) external;
    function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 principalToWithdraw, uint256 minReceived)
        external
        payable;
}

interface IModuleRegistryComp {
    function registerModule(bytes32 metadataHash) external payable returns (uint256 moduleId);
}

interface IIlmIsolatedAdminComp {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function setMaxStaleness(uint256 maxStaleness) external;
    function createIlmIsolatedMarket(IlmIsolatedTypes.IlmIsolatedMarketParams calldata params, uint256 moduleId)
        external
        returns (bytes32 marketId);
}

interface IIlmIsolatedComp {
    function isolatedSupply(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
    function isolatedSupplyCollateral(bytes32 marketId, uint256 assets, uint256 positionId) external;
    function isolatedBorrow(bytes32 marketId, uint256 assets, uint256 shares, uint256 positionId)
        external
        returns (uint256 assetsOut, uint256 sharesOut);
}

interface IIlmIsolatedLiqComp {
    function isolatedLiquidate(
        bytes32 marketId,
        uint256 borrowerPositionId,
        uint256 seizedAssets,
        uint256 repaidShares,
        uint256 liquidatorPositionId
    ) external returns (uint256 seizedOut, uint256 repaidAssetsOut);
}

interface IIlmIsolatedViewComp {
    function getIsolatedPosition(bytes32 marketId, bytes32 positionKey)
        external
        view
        returns (IlmIsolatedTypes.IlmIsolatedPosition memory position);
}

contract MutableOracleCompareAdapter is IIlmIsolatedOracleAdapter {
    uint256 internal _price;
    uint256 internal _updatedAt;

    function setPrice(uint256 price, uint256 updatedAt) external {
        _price = price;
        _updatedAt = updatedAt;
    }

    function getIsolatedPrice(address) external view returns (uint256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}

contract IlmOwnerHarnessFacet {
    function setIlmOwnerRaw(address owner_) external {
        LibIlmIsolatedStorage.s().owner = owner_;
    }
}

interface IIlmOwnerHarness {
    function setIlmOwnerRaw(address owner_) external;
}

contract DirectAmmRollingLoopRealFlowIntegrationTest is DirectAmmRollingLoopIntegrationTest {
    function test_RollingLoopRealFlow_withCadenceAndPayment() public {
        uint256 auctionId = _createAmmAuction();
        uint256 offerId = _postRollingOffer(Math.mulDiv(BORROW_AMOUNT, 1, PRICE_DENOMINATOR));

        vm.prank(userA);
        uint256 agreementId = rollingAgreements.acceptRollingOffer(offerId, aPositionId, 0, 0);

        vm.prank(userA);
        (uint256 amountOut,) = amm.swapExactInOrFinalize(
            auctionId,
            address(token2),
            BORROW_AMOUNT / 2,
            BORROW_AMOUNT / 2,
            0,
            userA
        );
        assertGt(amountOut, 0, "swap output");

        vm.prank(userA);
        pm.depositToPosition(aPositionId, POOL_TOKEN1, amountOut, amountOut);

        DirectTypes.DirectRollingAgreement memory beforeAgreement = rollingAgreements.getRollingAgreement(agreementId);
        assertEq(uint8(beforeAgreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement active before due");

        vm.warp(block.timestamp + 30 days);

        (uint256 interestDue, uint256 totalDue) = rollingViews.calculateRollingPayment(agreementId);
        assertGt(totalDue, 0, "total due positive at cadence boundary");
        assertGe(totalDue, interestDue, "total due covers interest");

        vm.prank(userA);
        rollingPayments.makeRollingPayment(agreementId, totalDue, totalDue, 0);

        DirectTypes.DirectRollingAgreement memory afterAgreement = rollingAgreements.getRollingAgreement(agreementId);
        if (afterAgreement.paymentCount == beforeAgreement.paymentCount) {
            (, uint256 catchUpDue) = rollingViews.calculateRollingPayment(agreementId);
            uint256 catchUpAmount = catchUpDue + afterAgreement.arrears;
            vm.prank(userA);
            rollingPayments.makeRollingPayment(agreementId, catchUpAmount, catchUpAmount, 0);
            afterAgreement = rollingAgreements.getRollingAgreement(agreementId);
        }

        assertEq(uint8(afterAgreement.status), uint8(DirectTypes.DirectStatus.Active), "agreement remains active");
        assertGt(afterAgreement.paymentCount, beforeAgreement.paymentCount, "payment count increments");
        assertEq(afterAgreement.outstandingPrincipal, beforeAgreement.outstandingPrincipal, "principal unchanged when amortization disabled");
    }
}

contract DirectVsIlmShockComparisonIntegrationTest is DirectAmmRollingLoopIntegrationTest {
    uint256 internal constant ILM_LOOP_BORROW_1 = 2_000 ether;
    uint256 internal constant ILM_LOOP_BORROW_2 = 1_000 ether;

    bool internal ilmWired;

    MutableOracleCompareAdapter internal oracle;
    IlmManagedFixedRateIrm internal irm;

    IPositionManagementExtended internal pmExt;
    IModuleRegistryComp internal moduleRegistry;
    IIlmIsolatedAdminComp internal ilmAdmin;
    IIlmIsolatedComp internal ilm;
    IIlmIsolatedLiqComp internal ilmLiq;
    IIlmIsolatedViewComp internal ilmView;
    IIlmOwnerHarness internal ilmHarness;

    function test_WickShock_ilmLiquidates_rollingStaysActiveUntilDue() public {
        _wireIlmAndWithdrawSelectors();

        uint256 auctionId = _createAmmAuction();

        uint256 rollingOfferId = _postRollingOffer(Math.mulDiv(BORROW_AMOUNT, 1, PRICE_DENOMINATOR));
        vm.prank(userA);
        uint256 rollingAgreementId = rollingAgreements.acceptRollingOffer(rollingOfferId, aPositionId, 0, 0);

        vm.prank(userA);
        (uint256 rollingSwapOut,) = amm.swapExactInOrFinalize(auctionId, address(token2), BORROW_AMOUNT, BORROW_AMOUNT, 0, userA);
        vm.prank(userA);
        pm.depositToPosition(aPositionId, POOL_TOKEN1, rollingSwapOut, rollingSwapOut);

        bytes32 marketId = _createIlmMarket();

        token1.mint(userA, 3 ether);
        token2.mint(userB, 25_000 ether);
        token2.mint(userC, 25_000 ether);

        vm.startPrank(userA);
        uint256 ilmBorrowerPositionId = pmExt.mintPositionWithDeposit(POOL_TOKEN1, 3 ether, 3 ether, 0);
        vm.stopPrank();

        vm.startPrank(userB);
        uint256 ilmLenderPositionId = pmExt.mintPositionWithDeposit(POOL_TOKEN2, 25_000 ether, 25_000 ether, 0);
        vm.stopPrank();

        vm.startPrank(userC);
        uint256 ilmLiquidatorPositionId = pmExt.mintPositionWithDeposit(POOL_TOKEN2, 25_000 ether, 25_000 ether, 0);
        vm.stopPrank();

        vm.prank(userB);
        ilm.isolatedSupply(marketId, 20_000 ether, 0, ilmLenderPositionId);

        vm.prank(userA);
        ilm.isolatedSupplyCollateral(marketId, 1 ether, ilmBorrowerPositionId);

        vm.prank(userA);
        ilm.isolatedBorrow(marketId, ILM_LOOP_BORROW_1, 0, ilmBorrowerPositionId);

        vm.prank(userA);
        pmExt.withdrawFromPosition(ilmBorrowerPositionId, POOL_TOKEN2, ILM_LOOP_BORROW_1, 0);

        vm.prank(userA);
        (uint256 ilmSwapOut1,) = amm.swapExactInOrFinalize(auctionId, address(token2), ILM_LOOP_BORROW_1, ILM_LOOP_BORROW_1, 0, userA);

        vm.prank(userA);
        pmExt.depositToPosition(ilmBorrowerPositionId, POOL_TOKEN1, ilmSwapOut1, ilmSwapOut1);

        vm.prank(userA);
        ilm.isolatedSupplyCollateral(marketId, ilmSwapOut1, ilmBorrowerPositionId);

        vm.prank(userA);
        ilm.isolatedBorrow(marketId, ILM_LOOP_BORROW_2, 0, ilmBorrowerPositionId);

        token1.mint(userC, 80 ether);
        vm.prank(userC);
        amm.swapExactInOrFinalize(auctionId, address(token1), 80 ether, 80 ether, 0, userC);

        oracle.setPrice(1_500 * IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        bytes32 ilmBorrowerKey = nft.getPositionKey(ilmBorrowerPositionId);
        IlmIsolatedTypes.IlmIsolatedPosition memory ilmBefore = ilmView.getIsolatedPosition(marketId, ilmBorrowerKey);

        vm.prank(userC);
        (uint256 seizedOut, uint256 repaidAssetsOut) = ilmLiq.isolatedLiquidate(
            marketId,
            ilmBorrowerPositionId,
            2e17, // 0.2 token1
            0,
            ilmLiquidatorPositionId
        );
        assertGt(seizedOut, 0, "ILM seized collateral");
        assertGt(repaidAssetsOut, 0, "ILM repaid assets");

        IlmIsolatedTypes.IlmIsolatedPosition memory ilmAfter = ilmView.getIsolatedPosition(marketId, ilmBorrowerKey);
        assertLt(uint256(ilmAfter.borrowShares), uint256(ilmBefore.borrowShares), "ILM borrow shares reduced by liquidation");

        DirectTypes.DirectRollingAgreement memory rollingAfterWick = rollingAgreements.getRollingAgreement(rollingAgreementId);
        assertEq(uint8(rollingAfterWick.status), uint8(DirectTypes.DirectStatus.Active), "rolling remains active at wick time");

        vm.prank(userC);
        vm.expectRevert(RollingError_RecoveryNotEligible.selector);
        rollingLifecycle.recoverRolling(rollingAgreementId);
    }

    function _wireIlmAndWithdrawSelectors() internal {
        if (ilmWired) {
            return;
        }

        PositionManagementFacet pmFacet = new PositionManagementFacet();
        ModuleRegistryFacet moduleRegistryFacet = new ModuleRegistryFacet();
        ILMIsolatedAdminFacet ilmAdminFacet = new ILMIsolatedAdminFacet();
        ILMIsolatedFacet ilmFacet = new ILMIsolatedFacet();
        ILMIsolatedLiquidationFacet ilmLiqFacet = new ILMIsolatedLiquidationFacet();
        ILMIsolatedViewFacet ilmViewFacet = new ILMIsolatedViewFacet();
        IlmOwnerHarnessFacet ownerHarness = new IlmOwnerHarnessFacet();

        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](7);
        addCuts[0] = _cut(address(pmFacet), _selectorsWithdrawOnly());
        addCuts[1] = _cut(address(moduleRegistryFacet), _selectorsModuleRegistry());
        addCuts[2] = _cut(address(ilmAdminFacet), _selectorsIlmAdmin());
        addCuts[3] = _cut(address(ilmFacet), _selectorsIlm());
        addCuts[4] = _cut(address(ilmLiqFacet), _selectorsIlmLiquidation());
        addCuts[5] = _cut(address(ilmViewFacet), _selectorsIlmView());
        addCuts[6] = _cut(address(ownerHarness), _selectorsIlmHarness());
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");

        pmExt = IPositionManagementExtended(address(diamond));
        moduleRegistry = IModuleRegistryComp(address(diamond));
        ilmAdmin = IIlmIsolatedAdminComp(address(diamond));
        ilm = IIlmIsolatedComp(address(diamond));
        ilmLiq = IIlmIsolatedLiqComp(address(diamond));
        ilmView = IIlmIsolatedViewComp(address(diamond));
        ilmHarness = IIlmOwnerHarness(address(diamond));

        ilmHarness.setIlmOwnerRaw(address(this));
        oracle = new MutableOracleCompareAdapter();
        irm = new IlmManagedFixedRateIrm(0);

        ilmWired = true;
    }

    function _createIlmMarket() internal returns (bytes32 marketId) {
        oracle.setPrice(3_500 * IlmIsolatedTypes.ORACLE_PRICE_SCALE, block.timestamp);

        uint256 moduleId = moduleRegistry.registerModule(keccak256("ILM_COMPARE_MODULE"));

        ilmAdmin.enableIrm(address(irm));
        ilmAdmin.enableLltv(75e16);
        ilmAdmin.setMaxStaleness(2 days);

        marketId = ilmAdmin.createIlmIsolatedMarket(
            IlmIsolatedTypes.IlmIsolatedMarketParams({
                loanPoolId: POOL_TOKEN2,
                collateralPoolId: POOL_TOKEN1,
                oracle: address(oracle),
                irm: address(irm),
                lltv: 75e16
            }),
            moduleId
        );
    }

    function _selectorsWithdrawOnly() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256("withdrawFromPosition(uint256,uint256,uint256,uint256)"));
    }

    function _selectorsModuleRegistry() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ModuleRegistryFacet.registerModule.selector;
    }

    function _selectorsIlmAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = ILMIsolatedAdminFacet.enableIrm.selector;
        s[1] = ILMIsolatedAdminFacet.enableLltv.selector;
        s[2] = ILMIsolatedAdminFacet.setMaxStaleness.selector;
        s[3] = ILMIsolatedAdminFacet.createIlmIsolatedMarket.selector;
    }

    function _selectorsIlm() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = ILMIsolatedFacet.isolatedSupply.selector;
        s[1] = ILMIsolatedFacet.isolatedSupplyCollateral.selector;
        s[2] = ILMIsolatedFacet.isolatedBorrow.selector;
    }

    function _selectorsIlmLiquidation() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ILMIsolatedLiquidationFacet.isolatedLiquidate.selector;
    }

    function _selectorsIlmView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ILMIsolatedViewFacet.getIsolatedPosition.selector;
    }

    function _selectorsIlmHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IIlmOwnerHarness.setIlmOwnerRaw.selector;
    }
}
