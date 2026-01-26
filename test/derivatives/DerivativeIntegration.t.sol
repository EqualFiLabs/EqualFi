// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {MamCurveManagementFacet} from "../../src/EqualX/MamCurveManagementFacet.sol";
import {MamCurveExecutionFacet} from "../../src/EqualX/MamCurveExecutionFacet.sol";
import {MamCurveFacet} from "../../src/EqualX/MamCurveFacet.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../../src/derivatives/FuturesFacet.sol";
import {DerivativeViewFacet} from "../../src/views/DerivativeViewFacet.sol";
import {MamCurveViewFacet} from "../../src/views/MamCurveViewFacet.sol";
import {DerivativeTypes} from "../../src/libraries/DerivativeTypes.sol";
import {MamTypes} from "../../src/libraries/MamTypes.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "../../src/libraries/LibPoolMembership.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibDerivativeStorage} from "../../src/libraries/LibDerivativeStorage.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDirectStorage} from "../../src/libraries/LibDirectStorage.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibEncumbrance} from "../../src/libraries/LibEncumbrance.sol";

interface IDerivativeTestHarness {
    function setPositionNFT(address nft) external;
    function setTreasury(address treasury) external;
    function setMakerShares(uint16 ammShareBps, uint16 communityShareBps, uint16 mamShareBps) external;
    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal, uint256 tracked) external;
    function addPrincipal(uint256 pid, bytes32 positionKey, uint256 principal, uint256 tracked) external;
    function joinPool(uint256 pid, bytes32 positionKey) external;
    function setEuropeanTolerance(uint64 tolerance) external;
    function setGracePeriod(uint64 gracePeriod) external;
    function getDirectLocked(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function getDirectLent(bytes32 positionKey, uint256 pid) external view returns (uint256);
    function getPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256);
    function getTracked(uint256 pid) external view returns (uint256);
}

contract DerivativeTestHarnessFacet {
    function setPositionNFT(address nftAddr) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nftAddr;
        ns.nftModeEnabled = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setMakerShares(uint16 ammShareBps, uint16 communityShareBps, uint16 mamShareBps) external {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        ds.config.ammMakerShareBps = ammShareBps;
        ds.config.communityMakerShareBps = communityShareBps;
        ds.config.mamMakerShareBps = mamShareBps;
    }

    function seedPool(
        uint256 pid,
        address underlying,
        bytes32 positionKey,
        uint256 principal,
        uint256 tracked
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = tracked;
        if (tracked > 0) {
            MockERC20(underlying).mint(address(this), tracked);
        }
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.activeCreditIndex == 0) {
            p.activeCreditIndex = LibActiveCreditIndex.INDEX_SCALE;
        }
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function addPrincipal(uint256 pid, bytes32 positionKey, uint256 principal, uint256 tracked) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "Pool not initialized");
        if (p.feeIndex == 0) {
            p.feeIndex = LibFeeIndex.INDEX_SCALE;
        }
        if (p.maintenanceIndex == 0) {
            p.maintenanceIndex = LibFeeIndex.INDEX_SCALE;
        }
        p.userPrincipal[positionKey] += principal;
        p.totalDeposits += principal;
        p.trackedBalance += tracked;
        if (tracked > 0) {
            MockERC20(p.underlying).mint(address(this), tracked);
        }
        if (p.userFeeIndex[positionKey] == 0) {
            p.userFeeIndex[positionKey] = p.feeIndex;
        }
        if (p.userMaintenanceIndex[positionKey] == 0) {
            p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        }
    }

    function joinPool(uint256 pid, bytes32 positionKey) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function setEuropeanTolerance(uint64 tolerance) external {
        LibDerivativeStorage.derivativeStorage().config.europeanToleranceSeconds = tolerance;
    }

    function setGracePeriod(uint64 gracePeriod) external {
        LibDerivativeStorage.derivativeStorage().config.defaultGracePeriodSeconds = gracePeriod;
    }

    function getDirectLocked(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
    }

    function getDirectLent(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLent;
    }

    function getPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function getTracked(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }
}

abstract contract DerivativeDiamondTestBase is Test {
    Diamond internal diamond;
    IDerivativeTestHarness internal harness;
    AmmAuctionFacet internal amm;
    MamCurveFacet internal mam;
    CommunityAuctionFacet internal community;
    OptionsFacet internal options;
    FuturesFacet internal futures;
    DerivativeViewFacet internal derivativeView;
    MamCurveViewFacet internal mamView;
    PositionNFT internal nft;
    OptionToken internal optionToken;
    FuturesToken internal futuresToken;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    function setUpDiamond() internal {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();

        AmmAuctionFacet ammFacet = new AmmAuctionFacet();
        MamCurveCreationFacet mamCreateFacet = new MamCurveCreationFacet();
        MamCurveManagementFacet mamManageFacet = new MamCurveManagementFacet();
        MamCurveExecutionFacet mamExecFacet = new MamCurveExecutionFacet();
        CommunityAuctionFacet communityFacet = new CommunityAuctionFacet();
        OptionsFacet optionsFacet = new OptionsFacet();
        FuturesFacet futuresFacet = new FuturesFacet();
        DerivativeViewFacet viewFacet = new DerivativeViewFacet();
        MamCurveViewFacet mamViewFacet = new MamCurveViewFacet();
        DerivativeTestHarnessFacet harnessFacet = new DerivativeTestHarnessFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(loupeFacet), _selectorsLoupe());
        cuts[2] = _cut(address(ownershipFacet), _selectorsOwnership());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](10);
        addCuts[0] = _cut(address(harnessFacet), _selectorsHarness());
        addCuts[1] = _cut(address(ammFacet), _selectorsAmm());
        addCuts[2] = _cut(address(mamCreateFacet), _selectorsMamCreate());
        addCuts[3] = _cut(address(mamManageFacet), _selectorsMamManage());
        addCuts[4] = _cut(address(mamExecFacet), _selectorsMamExec());
        addCuts[5] = _cut(address(communityFacet), _selectorsCommunity());
        addCuts[6] = _cut(address(optionsFacet), _selectorsOptions());
        addCuts[7] = _cut(address(futuresFacet), _selectorsFutures());
        addCuts[8] = _cut(address(viewFacet), _selectorsView(viewFacet));
        addCuts[9] = _cut(address(mamViewFacet), _selectorsMamView(mamViewFacet));
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");

        harness = IDerivativeTestHarness(address(diamond));
        amm = AmmAuctionFacet(address(diamond));
        mam = MamCurveFacet(address(diamond));
        community = CommunityAuctionFacet(address(diamond));
        options = OptionsFacet(address(diamond));
        futures = FuturesFacet(address(diamond));
        derivativeView = DerivativeViewFacet(address(diamond));
        mamView = MamCurveViewFacet(address(diamond));

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));
        harness.setTreasury(address(0xC0FFEE));
        harness.setMakerShares(7000, 7000, 7000);

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 6, 0);
        tokenC = new MockERC20("TokenC", "TKC", 18, 0);

        optionToken = new OptionToken("", address(this), address(diamond));
        futuresToken = new FuturesToken("", address(this), address(diamond));
        options.setOptionToken(address(optionToken));
        futures.setFuturesToken(address(futuresToken));

        harness.setEuropeanTolerance(100);
        harness.setGracePeriod(2 days);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsLoupe() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectorsOwnership() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectorsHarness() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = DerivativeTestHarnessFacet.setPositionNFT.selector;
        s[1] = DerivativeTestHarnessFacet.setTreasury.selector;
        s[2] = DerivativeTestHarnessFacet.setMakerShares.selector;
        s[3] = DerivativeTestHarnessFacet.seedPool.selector;
        s[4] = DerivativeTestHarnessFacet.addPrincipal.selector;
        s[5] = DerivativeTestHarnessFacet.joinPool.selector;
        s[6] = DerivativeTestHarnessFacet.setEuropeanTolerance.selector;
        s[7] = DerivativeTestHarnessFacet.setGracePeriod.selector;
        s[8] = DerivativeTestHarnessFacet.getDirectLocked.selector;
        s[9] = DerivativeTestHarnessFacet.getDirectLent.selector;
        s[10] = DerivativeTestHarnessFacet.getPrincipal.selector;
        s[11] = DerivativeTestHarnessFacet.getTracked.selector;
    }

    function _selectorsAmm() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = AmmAuctionFacet.setAmmPaused.selector;
        s[1] = AmmAuctionFacet.createAuction.selector;
        s[2] = AmmAuctionFacet.swapExactInOrFinalize.selector;
        s[3] = AmmAuctionFacet.cancelAuction.selector;
        s[4] = AmmAuctionFacet.getAuction.selector;
        s[5] = AmmAuctionFacet.previewSwap.selector;
    }

    function _selectorsMamCreate() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = MamCurveCreationFacet.setMamPaused.selector;
        s[1] = MamCurveCreationFacet.createCurve.selector;
        s[2] = MamCurveCreationFacet.createCurvesBatch.selector;
    }

    function _selectorsMamManage() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = MamCurveManagementFacet.updateCurve.selector;
        s[1] = MamCurveManagementFacet.updateCurvesBatch.selector;
        s[2] = MamCurveManagementFacet.cancelCurve.selector;
        s[3] = MamCurveManagementFacet.cancelCurvesBatch.selector;
        s[4] = MamCurveManagementFacet.expireCurve.selector;
        s[5] = MamCurveManagementFacet.expireCurvesBatch.selector;
    }

    function _selectorsMamExec() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = MamCurveExecutionFacet.loadCurveForFill.selector;
        s[1] = MamCurveExecutionFacet.executeCurveSwap.selector;
    }

    function _selectorsCommunity() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = CommunityAuctionFacet.createCommunityAuction.selector;
        s[1] = CommunityAuctionFacet.joinCommunityAuction.selector;
        s[2] = CommunityAuctionFacet.leaveCommunityAuction.selector;
        s[3] = CommunityAuctionFacet.claimFees.selector;
        s[4] = CommunityAuctionFacet.swapExactIn.selector;
        s[5] = CommunityAuctionFacet.finalizeAuction.selector;
        s[6] = CommunityAuctionFacet.cancelCommunityAuction.selector;
        s[7] = CommunityAuctionFacet.getCommunityAuction.selector;
        s[8] = CommunityAuctionFacet.getMakerShare.selector;
        s[9] = CommunityAuctionFacet.previewJoin.selector;
        s[10] = CommunityAuctionFacet.previewLeave.selector;
        s[11] = CommunityAuctionFacet.getTotalMakers.selector;
    }

    function _selectorsMamView(MamCurveViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _selectorsOptions() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = OptionsFacet.setOptionToken.selector;
        s[1] = OptionsFacet.setOptionsPaused.selector;
        s[2] = OptionsFacet.createOptionSeries.selector;
        s[3] = OptionsFacet.exerciseOptions.selector;
        s[4] = OptionsFacet.exerciseOptionsFor.selector;
        s[5] = OptionsFacet.reclaimOptions.selector;
    }

    function _selectorsFutures() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = FuturesFacet.setFuturesToken.selector;
        s[1] = FuturesFacet.setFuturesPaused.selector;
        s[2] = FuturesFacet.createFuturesSeries.selector;
        s[3] = FuturesFacet.settleFutures.selector;
        s[4] = FuturesFacet.settleFuturesFor.selector;
        s[5] = FuturesFacet.reclaimFutures.selector;
    }

    function _selectorsView(DerivativeViewFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
    }

    function _position(uint256 tokenId) internal view returns (bytes32) {
        return nft.getPositionKey(tokenId);
    }

    function _strikeAmount(uint256 amount, uint256 strikePrice) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(tokenA.decimals());
        uint256 strikeScale = 10 ** uint256(tokenB.decimals());
        uint256 normalizedUnderlying = Math.mulDiv(amount, strikePrice, underlyingScale);
        return Math.mulDiv(normalizedUnderlying, strikeScale, 1e18);
    }

    function _quoteAmount(uint256 amount, uint256 forwardPrice) internal view returns (uint256) {
        uint256 underlyingScale = 10 ** uint256(tokenA.decimals());
        uint256 quoteScale = 10 ** uint256(tokenC.decimals());
        uint256 normalizedUnderlying = Math.mulDiv(amount, forwardPrice, underlyingScale);
        return Math.mulDiv(normalizedUnderlying, quoteScale, 1e18);
    }
}

contract DerivativeIntegrationTest is DerivativeDiamondTestBase {
    address internal maker = address(0xA11CE);
    address internal holder = address(0xB0B);
    address internal makerTwo = address(0xD00D);
    address internal swapper = address(0xC0FFEE);
    address internal treasury = address(0xC0FFEE);

    function setUp() public {
        setUpDiamond();
        vm.warp(1);
    }

    function testIntegration_AmmLifecycle() public {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 key = _position(tokenId);
        _seedPool(1, tokenA, key, 10e18);
        _seedPool(2, tokenB, key, 10_000e6);

        vm.prank(maker);
        uint256 auctionId = amm.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: tokenId,
                poolIdA: 1,
                poolIdB: 2,
                reserveA: 2e18,
                reserveB: 4_000e6,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        assertEq(harness.getDirectLent(key, 1), 2e18, "reserve A lent");
        assertEq(harness.getDirectLent(key, 2), 4_000e6, "reserve B lent");

        tokenA.mint(swapper, 1e18);
        vm.prank(swapper);
        tokenA.approve(address(diamond), 1e18);
        vm.prank(swapper);
        (uint256 amountOutA, bool finalizedA) =
            amm.swapExactInOrFinalize(auctionId, address(tokenA), 1e18, 0, swapper);
        assertTrue(amountOutA > 0, "amm swap out A");
        assertFalse(finalizedA, "amm not finalized");

        tokenB.mint(swapper, 2_000e6);
        vm.prank(swapper);
        tokenB.approve(address(diamond), 2_000e6);
        vm.prank(swapper);
        (uint256 amountOutB, bool finalizedB) =
            amm.swapExactInOrFinalize(auctionId, address(tokenB), 2_000e6, 0, swapper);
        assertTrue(amountOutB > 0, "amm swap out B");
        assertFalse(finalizedB, "amm not finalized");

        DerivativeTypes.AmmAuction memory auction = amm.getAuction(auctionId);
        (uint256 makerFeeA, uint256 makerFeeB) = amm.getAuctionFees(auctionId);
        assertTrue(makerFeeA + makerFeeB > 0, "maker fees accrued");

        uint256 principalA = harness.getPrincipal(1, key);
        uint256 principalB = harness.getPrincipal(2, key);

        vm.warp(block.timestamp + 2 days);
        (, bool finalized) = amm.swapExactInOrFinalize(auctionId, address(tokenA), 1, 0, swapper);
        assertTrue(finalized, "amm finalized");

        assertEq(harness.getDirectLent(key, 1), 0, "lent A cleared");
        assertEq(harness.getDirectLent(key, 2), 0, "lent B cleared");

        uint256 totalFeeA = (1e18 * 30) / 10_000;
        uint256 totalFeeB = (2_000e6 * 30) / 10_000;
        uint256 protocolFeeA = totalFeeA - makerFeeA;
        uint256 protocolFeeB = totalFeeB - makerFeeB;
        uint256 treasuryFeeA = treasury != address(0) ? (protocolFeeA * 2000) / 10_000 : 0;
        uint256 treasuryFeeB = treasury != address(0) ? (protocolFeeB * 2000) / 10_000 : 0;
        uint256 protocolYieldA = protocolFeeA - treasuryFeeA;
        uint256 protocolYieldB = protocolFeeB - treasuryFeeB;
        uint256 expectedPrincipalA = principalA + auction.reserveA - auction.initialReserveA - protocolYieldA;
        uint256 expectedPrincipalB = principalB + auction.reserveB - auction.initialReserveB - protocolYieldB;

        assertEq(harness.getPrincipal(1, key), expectedPrincipalA, "principal A reconciled");
        assertEq(harness.getPrincipal(2, key), expectedPrincipalB, "principal B reconciled");
        assertTrue(tokenA.balanceOf(treasury) > 0 || tokenB.balanceOf(treasury) > 0, "treasury fee paid");
    }

    function testIntegration_MamCurveLifecycle() public {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 key = _position(tokenId);
        _seedPool(1, tokenA, key, 10e18);
        _seedPool(2, tokenB, key, 10_000e6);

        MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
            makerPositionKey: key,
            makerPositionId: tokenId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 1e18,
            startPrice: 2e18,
            endPrice: 1e18,
            startTime: uint64(block.timestamp),
            duration: 1 days,
            generation: 1,
            feeRateBps: 100,
            feeAsset: MamTypes.FeeAsset.TokenIn,
            salt: 1
        });

        vm.prank(maker);
        uint256 curveId = mam.createCurve(desc);
        (MamTypes.StoredCurve memory stored,,,,) = mamView.getCurve(curveId);
        assertTrue(stored.active, "curve active");
        assertEq(harness.getDirectLocked(key, 1), 1e18, "base locked");

        uint256 amountIn = 2_000e6;
        uint256 feeAmount = (amountIn * 100) / 10_000;
        uint256 totalIn = amountIn + feeAmount;
        tokenB.mint(swapper, totalIn);
        vm.prank(swapper);
        tokenB.approve(address(diamond), totalIn);

        vm.prank(swapper);
        mam.executeCurveSwap(curveId, amountIn, 1, uint64(block.timestamp + 1 days), swapper);

        uint256 expectedBaseFill = (amountIn * 1e18) / 2e18;
        assertEq(harness.getDirectLocked(key, 1), 1e18 - expectedBaseFill, "base unlocked");
        assertEq(tokenA.balanceOf(swapper), expectedBaseFill, "base delivered");

        uint256 makerQuote = harness.getPrincipal(2, key);
        assertTrue(makerQuote > 10_000e6, "maker quote increased");
        assertEq(tokenB.balanceOf(treasury) > 0, true, "treasury fee paid");
    }

    function testIntegration_CommunityMultiMakerPartialExit() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = _position(makerTokenId);
        _seedPool(61, tokenA, makerKey, 10e18);
        _seedPool(62, tokenB, makerKey, 20_000e6);

        uint256 joinerTokenId = nft.mint(holder, 1);
        bytes32 joinerKey = _position(joinerTokenId);
        harness.addPrincipal(61, joinerKey, 5e18, 5e18);
        harness.addPrincipal(62, joinerKey, 10_000e6, 10_000e6);
        harness.joinPool(61, joinerKey);
        harness.joinPool(62, joinerKey);

        uint256 secondTokenId = nft.mint(makerTwo, 1);
        bytes32 secondKey = _position(secondTokenId);
        harness.addPrincipal(61, secondKey, 5e18, 5e18);
        harness.addPrincipal(62, secondKey, 10_000e6, 10_000e6);
        harness.joinPool(61, secondKey);
        harness.joinPool(62, secondKey);

        vm.prank(maker);
        uint256 auctionId = community.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 61,
                poolIdB: 62,
                reserveA: 2e18,
                reserveB: 4_000e6,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        vm.prank(holder);
        community.joinCommunityAuction(auctionId, joinerTokenId, 1e18, 2_000e6);
        vm.prank(makerTwo);
        community.joinCommunityAuction(auctionId, secondTokenId, 5e17, 1_000e6);

        tokenA.mint(swapper, 2e17);
        vm.prank(swapper);
        tokenA.approve(address(diamond), 2e17);
        vm.prank(swapper);
        community.swapExactIn(auctionId, address(tokenA), 2e17, 0, swapper);

        vm.prank(holder);
        (, , uint256 feesA, uint256 feesB) = community.leaveCommunityAuction(auctionId, joinerTokenId);
        assertTrue(feesA > 0 || feesB > 0, "fees accrued for leaver");

        DerivativeTypes.CommunityAuction memory auction = community.getCommunityAuction(auctionId);
        assertTrue(auction.active, "auction stays active");
        assertFalse(auction.finalized, "auction not finalized");
        assertEq(auction.makerCount, 2, "maker count after leave");
    }

    function testIntegration_CommunityCreatorLeavesOthersRemain() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = _position(makerTokenId);
        _seedPool(71, tokenA, makerKey, 8e18);
        _seedPool(72, tokenB, makerKey, 16_000e6);

        uint256 joinerTokenId = nft.mint(holder, 1);
        bytes32 joinerKey = _position(joinerTokenId);
        harness.addPrincipal(71, joinerKey, 4e18, 4e18);
        harness.addPrincipal(72, joinerKey, 8_000e6, 8_000e6);
        harness.joinPool(71, joinerKey);
        harness.joinPool(72, joinerKey);

        vm.prank(maker);
        uint256 auctionId = community.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 71,
                poolIdB: 72,
                reserveA: 2e18,
                reserveB: 4_000e6,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 0,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        vm.prank(holder);
        community.joinCommunityAuction(auctionId, joinerTokenId, 1e18, 2_000e6);

        vm.prank(maker);
        community.leaveCommunityAuction(auctionId, makerTokenId);

        DerivativeTypes.CommunityAuction memory auction = community.getCommunityAuction(auctionId);
        assertTrue(auction.active, "auction still active");
        assertFalse(auction.finalized, "auction not finalized");
        assertEq(auction.makerCount, 1, "single maker remains");
        (uint256 joinerShare,,) = community.getMakerShare(auctionId, joinerKey);
        assertTrue(joinerShare > 0, "joiner retains share");
    }

    function testIntegration_CommunityFeeAccumulationManySwaps() public {
        uint256 makerTokenId = nft.mint(maker, 1);
        bytes32 makerKey = _position(makerTokenId);
        _seedPool(81, tokenA, makerKey, 10e18);
        _seedPool(82, tokenB, makerKey, 20_000e6);

        vm.prank(maker);
        uint256 auctionId = community.createCommunityAuction(
            DerivativeTypes.CreateCommunityAuctionParams({
                positionId: makerTokenId,
                poolIdA: 81,
                poolIdB: 82,
                reserveA: 2e18,
                reserveB: 4_000e6,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        uint256 swapAmount = 1e16;
        tokenA.mint(swapper, swapAmount * 20);
        vm.prank(swapper);
        tokenA.approve(address(diamond), swapAmount * 20);

        uint256 pendingBefore;
        (, pendingBefore,) = community.getMakerShare(auctionId, makerKey);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(swapper);
            community.swapExactIn(auctionId, address(tokenA), swapAmount, 0, swapper);
        }
        uint256 pendingAfter;
        (, pendingAfter,) = community.getMakerShare(auctionId, makerKey);
        assertTrue(pendingAfter > pendingBefore, "fees increase after swaps");
    }

    function testIntegration_OptionsLifecycleCall() public {
        _optionsLifecycle(true);
    }

    function testIntegration_OptionsLifecyclePut() public {
        _optionsLifecycle(false);
    }

    function _optionsLifecycle(bool isCall) internal {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 key = _position(tokenId);
        uint256 poolUnderlying = isCall ? 11 : 13;
        uint256 poolStrike = isCall ? 12 : 14;
        _seedPool(poolUnderlying, tokenA, key, 3e18);
        _seedPool(poolStrike, tokenB, key, 10_000e6);

        vm.prank(maker);
        uint256 seriesId = options.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: tokenId,
                underlyingPoolId: poolUnderlying,
                strikePoolId: poolStrike,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 2e18,
                isCall: isCall,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        if (isCall) {
            uint256 strikeAmount = _strikeAmount(1e18, 2e18);
            tokenB.mint(holder, strikeAmount);
            vm.prank(holder);
            tokenB.approve(address(diamond), strikeAmount);
        } else {
            tokenA.mint(holder, 1e18);
            vm.prank(holder);
            tokenA.approve(address(diamond), 1e18);
        }

        vm.prank(holder);
        options.exerciseOptions(seriesId, 1e18, holder);

        uint256 expectedLocked = isCall ? 1e18 : _strikeAmount(1e18, 2e18);
        assertEq(harness.getDirectLocked(key, isCall ? poolUnderlying : poolStrike), expectedLocked, "locked after exercise");

        vm.warp(block.timestamp + 8 days);
        vm.prank(maker);
        options.reclaimOptions(seriesId);
        assertEq(harness.getDirectLocked(key, isCall ? poolUnderlying : poolStrike), 0, "locked after reclaim");
    }

    function testIntegration_FuturesLifecycleAmerican() public {
        _futuresLifecycle(false);
    }

    function testIntegration_FuturesLifecycleEuropean() public {
        _futuresLifecycle(true);
    }

    function _futuresLifecycle(bool isEuropean) internal {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 key = _position(tokenId);
        uint256 poolUnderlying = isEuropean ? 21 : 23;
        uint256 poolQuote = isEuropean ? 22 : 24;
        _seedPool(poolUnderlying, tokenA, key, 3e18);
        _seedPool(poolQuote, tokenC, key, 10e18);

        vm.prank(maker);
        uint256 seriesId = futures.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: tokenId,
                underlyingPoolId: poolUnderlying,
                quotePoolId: poolQuote,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 2e18,
                isEuropean: isEuropean,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 quoteAmount = _quoteAmount(1e18, 2e18);
        tokenC.mint(holder, quoteAmount);
        vm.prank(holder);
        tokenC.approve(address(diamond), quoteAmount);

        if (isEuropean) {
            vm.warp(block.timestamp + 7 days);
        }

        vm.prank(holder);
        futures.settleFutures(seriesId, 1e18, holder);

        assertEq(harness.getDirectLocked(key, poolUnderlying), 1e18, "futures locked after settlement");

        uint64 graceUnlockTime = futures.getGraceUnlockTime(seriesId);
        vm.warp(graceUnlockTime);
        vm.prank(maker);
        futures.reclaimFutures(seriesId);
        assertEq(harness.getDirectLocked(key, poolUnderlying), 0, "futures locked after reclaim");
    }

    function testIntegration_MultiProductIsolation() public {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 key = _position(tokenId);
        _seedPool(31, tokenA, key, 5e18);
        _seedPool(32, tokenB, key, 10_000e6);
        _seedPool(33, tokenC, key, 10e18);

        vm.prank(maker);
        uint256 auctionId = amm.createAuction(
            DerivativeTypes.CreateAuctionParams({
                positionId: tokenId,
                poolIdA: 31,
                poolIdB: 32,
                reserveA: 1e18,
                reserveB: 2_000e6,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days),
                feeBps: 30,
                feeAsset: DerivativeTypes.FeeAsset.TokenIn
            })
        );

        vm.prank(maker);
        uint256 optionId = options.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: tokenId,
                underlyingPoolId: 31,
                strikePoolId: 32,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        vm.prank(maker);
        uint256 futuresId = futures.createFuturesSeries(
            DerivativeTypes.CreateFuturesSeriesParams({
                positionId: tokenId,
                underlyingPoolId: 31,
                quotePoolId: 33,
                forwardPrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isEuropean: false,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        assertEq(harness.getDirectLent(key, 31), 1e18, "amm lent underlying");
        assertEq(harness.getDirectLent(key, 32), 2_000e6, "amm lent quote");
        assertEq(harness.getDirectLocked(key, 31), 2e18, "locked for options + futures");

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, optionId, 1e18, "");
        uint256 strikeAmount = _strikeAmount(1e18, 2e18);
        tokenB.mint(holder, strikeAmount);
        vm.prank(holder);
        tokenB.approve(address(diamond), strikeAmount);
        vm.prank(holder);
        options.exerciseOptions(optionId, 1e18, holder);

        vm.prank(maker);
        futuresToken.safeTransferFrom(maker, holder, futuresId, 1e18, "");
        uint256 quoteAmount = _quoteAmount(1e18, 2e18);
        tokenC.mint(holder, quoteAmount);
        vm.prank(holder);
        tokenC.approve(address(diamond), quoteAmount);
        vm.prank(holder);
        futures.settleFutures(futuresId, 1e18, holder);

        vm.warp(block.timestamp + 2 days);
        (, bool finalized) = amm.swapExactInOrFinalize(auctionId, address(tokenA), 1, 0, swapper);
        assertTrue(finalized, "amm finalized");

        assertEq(harness.getDirectLent(key, 31), 0, "amm lent cleared");
        assertEq(harness.getDirectLocked(key, 31), 0, "locks cleared after exercise + settle");
        assertEq(harness.getDirectLocked(key, 33), 0, "quote pool unlocked");
    }

    function testIntegration_PositionNftTransfer() public {
        uint256 tokenId = nft.mint(maker, 1);
        bytes32 key = _position(tokenId);
        _seedPool(41, tokenA, key, 2e18);
        _seedPool(42, tokenB, key, 10_000e6);

        vm.prank(maker);
        uint256 seriesId = options.createOptionSeries(
            DerivativeTypes.CreateOptionSeriesParams({
                positionId: tokenId,
                underlyingPoolId: 41,
                strikePoolId: 42,
                strikePrice: 2e18,
                expiry: uint64(block.timestamp + 7 days),
                totalSize: 1e18,
                isCall: true,
                isAmerican: true,
                useCustomFees: false,
                createFeeBps: 0,
                exerciseFeeBps: 0,
                reclaimFeeBps: 0
            })
        );

        address newOwner = address(0xBEEF);
        vm.prank(maker);
        nft.transferFrom(maker, newOwner, tokenId);

        vm.warp(block.timestamp + 8 days);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, maker, tokenId));
        options.reclaimOptions(seriesId);

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, newOwner, seriesId, 1e18, "");

        vm.prank(newOwner);
        options.reclaimOptions(seriesId);
    }

    function _seedPool(uint256 pid, MockERC20 token, bytes32 key, uint256 principal) internal {
        harness.seedPool(pid, address(token), key, principal, principal);
        harness.joinPool(pid, key);
    }
}
