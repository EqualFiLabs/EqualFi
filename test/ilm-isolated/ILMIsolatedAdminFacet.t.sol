// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";
import {IIlmIsolatedIrmAdapter} from "../../src/ilm-isolated/interfaces/IIlmIsolatedIrmAdapter.sol";
import "../../src/ilm-isolated/errors/IlmIsolatedErrors.sol";

contract MockIlmIsolatedIrmAdapterAdmin is IIlmIsolatedIrmAdapter {
    uint256 internal _ratePerSecond;

    function setRate(uint256 ratePerSecond) external {
        _ratePerSecond = ratePerSecond;
    }

    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata,
        IlmIsolatedTypes.IlmIsolatedMarket calldata
    ) external view returns (uint256 ratePerSecond) {
        return _ratePerSecond;
    }
}

contract ILMIsolatedAdminFacetHarness is ILMIsolatedAdminFacet {
    function setOwnerRaw(address owner_) external {
        LibIlmIsolatedStorage.s().owner = owner_;
    }

    function setPositionNftRaw(address nft, bool enabled) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = enabled;
    }

    function setMarketState(bytes32 marketId, IlmIsolatedTypes.IlmIsolatedMarket calldata market) external {
        LibIlmIsolatedStorage.s().market[marketId] = market;
    }

    function getOwner() external view returns (address) {
        return LibIlmIsolatedStorage.s().owner;
    }

    function getFeeRecipientPositionKey() external view returns (bytes32) {
        return LibIlmIsolatedStorage.s().feeRecipientPositionKey;
    }

    function getMaxStaleness() external view returns (uint256) {
        return LibIlmIsolatedStorage.s().maxStaleness;
    }

    function getIrmEnabled(address irm) external view returns (bool) {
        return LibIlmIsolatedStorage.s().isIrmEnabled[irm];
    }

    function getLltvEnabled(uint256 lltv) external view returns (bool) {
        return LibIlmIsolatedStorage.s().isLltvEnabled[lltv];
    }

    function getMarket(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarket memory) {
        return LibIlmIsolatedStorage.s().market[marketId];
    }

    function getMarketParams(bytes32 marketId) external view returns (IlmIsolatedTypes.IlmIsolatedMarketParams memory) {
        return LibIlmIsolatedStorage.s().marketParams[marketId];
    }

    function getMarketModuleId(bytes32 marketId) external view returns (uint256) {
        return LibIlmIsolatedStorage.s().marketModuleId[marketId];
    }

    function getAuthorization(bytes32 positionKey, address operator) external view returns (bool) {
        return LibIlmIsolatedStorage.s().isAuthorizedOperator[positionKey][operator];
    }
}

contract ILMIsolatedAdminFacetTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant OPERATOR = address(0xCAFE);

    ILMIsolatedAdminFacetHarness internal h;
    MockIlmIsolatedIrmAdapterAdmin internal irm;

    function setUp() public {
        h = new ILMIsolatedAdminFacetHarness();
        irm = new MockIlmIsolatedIrmAdapterAdmin();
        h.setOwnerRaw(OWNER);
    }

    /// @dev Property 1: Market Creation Round-Trip
    /// Validates: Requirement 1.1
    function testFuzz_property1_marketCreationRoundTrip(
        uint256 loanPoolIdRaw,
        uint256 collateralPoolIdRaw,
        uint256 lltvRaw,
        uint256 moduleIdRaw,
        uint256 timestampRaw
    ) public {
        uint256 loanPoolId = bound(loanPoolIdRaw, 1, 1e12);
        uint256 collateralPoolId = bound(collateralPoolIdRaw, 1, 1e12);
        uint256 lltv = bound(lltvRaw, 1, IlmIsolatedTypes.WAD - 1);
        uint256 moduleId = bound(moduleIdRaw, 0, 1e12);
        uint256 timestamp_ = bound(timestampRaw, 1, type(uint128).max);

        vm.startPrank(OWNER);
        h.enableIrm(address(irm));
        h.enableLltv(lltv);
        vm.stopPrank();

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: loanPoolId,
            collateralPoolId: collateralPoolId,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: lltv
        });

        vm.warp(timestamp_);
        bytes32 marketId = h.createIlmIsolatedMarket(params, moduleId);

        bytes32 expectedId = keccak256(abi.encode(params));
        assertEq(marketId, expectedId);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory gotParams = h.getMarketParams(marketId);
        assertEq(gotParams.loanPoolId, loanPoolId);
        assertEq(gotParams.collateralPoolId, collateralPoolId);
        assertEq(gotParams.oracle, params.oracle);
        assertEq(gotParams.irm, params.irm);
        assertEq(gotParams.lltv, lltv);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = h.getMarket(marketId);
        assertEq(market.lastUpdate, uint128(timestamp_));
        assertEq(h.getMarketModuleId(marketId), moduleId);
    }

    /// @dev Property 2: Invalid Market Creation Rejection
    /// Validates: Requirements 1.2, 1.3, 1.4
    function test_property2_invalidMarketCreationRejection() public {
        uint256 lltv = 8e17;

        vm.prank(OWNER);
        h.enableLltv(lltv);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsIrmDisabled = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 11,
            collateralPoolId: 22,
            oracle: address(0x1234),
            irm: address(0x9999),
            lltv: lltv
        });
        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedIrmNotEnabled.selector, paramsIrmDisabled.irm));
        h.createIlmIsolatedMarket(paramsIrmDisabled, 1);

        vm.prank(OWNER);
        h.enableIrm(address(irm));

        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsLltvDisabled = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 11,
            collateralPoolId: 22,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: 7e17
        });
        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedLltvNotEnabled.selector, paramsLltvDisabled.lltv));
        h.createIlmIsolatedMarket(paramsLltvDisabled, 1);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsLltvGteWad = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 11,
            collateralPoolId: 22,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: IlmIsolatedTypes.WAD
        });
        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedLltvNotEnabled.selector, paramsLltvGteWad.lltv));
        h.createIlmIsolatedMarket(paramsLltvGteWad, 1);
    }

    /// @dev Property 3: Duplicate Market Rejection
    /// Validates: Requirement 1.5
    function test_property3_duplicateMarketRejection() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _createEnabledParams();

        bytes32 marketId = h.createIlmIsolatedMarket(params, 11);
        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedMarketAlreadyCreated.selector, marketId));
        h.createIlmIsolatedMarket(params, 22);
    }

    /// @dev Property 21: Admin Governance Round-Trip
    /// Validates: Requirements 15.1, 15.2, 15.3, 15.5, 15.6, 15.8
    function test_property21_adminGovernanceRoundTrip() public {
        uint256 lltv = 8e17;
        vm.startPrank(OWNER);
        h.enableIrm(address(irm));
        h.enableLltv(lltv);
        vm.stopPrank();
        assertTrue(h.getIrmEnabled(address(irm)));
        assertTrue(h.getLltvEnabled(lltv));

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 111,
            collateralPoolId: 222,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: lltv
        });
        bytes32 marketId = h.createIlmIsolatedMarket(params, 7);

        vm.warp(2 days + 1000);
        h.setMarketState(
            marketId,
            IlmIsolatedTypes.IlmIsolatedMarket({
                totalSupplyAssets: 1_000_000,
                totalSupplyShares: 1_000_000,
                totalBorrowAssets: 500_000,
                totalBorrowShares: 250_000,
                lastUpdate: uint128(block.timestamp - 1 days),
                fee: 0
            })
        );
        irm.setRate(1e12);

        vm.prank(OWNER);
        h.setFee(marketId, 1e17);

        IlmIsolatedTypes.IlmIsolatedMarket memory market = h.getMarket(marketId);
        assertEq(market.fee, uint128(1e17));
        assertGt(market.totalBorrowAssets, 500_000);
        assertGt(market.totalSupplyAssets, 1_000_000);
        assertEq(market.lastUpdate, uint128(block.timestamp));

        bytes32 feeRecipient = keccak256("treasury");
        vm.prank(OWNER);
        h.setFeeRecipientPositionKey(feeRecipient);
        assertEq(h.getFeeRecipientPositionKey(), feeRecipient);

        vm.prank(OWNER);
        h.setMaxStaleness(2 days);
        assertEq(h.getMaxStaleness(), 2 days);

        PositionNFT nft = _deployAndConfigurePositionNft();
        uint256 tokenId = nft.mint(OWNER, 1);
        bytes32 positionKey = nft.getPositionKey(tokenId);

        vm.prank(OWNER);
        h.setAuthorization(positionKey, OPERATOR, true);
        assertTrue(h.getAuthorization(positionKey, OPERATOR));

        vm.prank(OWNER);
        h.setOwner(OTHER);
        assertEq(h.getOwner(), OTHER);
    }

    /// @dev Property 22: Admin Access Control
    /// Validates: Requirement 15.7
    function test_property22_adminAccessControl() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _createEnabledParams();
        bytes32 marketId = h.createIlmIsolatedMarket(params, 1);

        vm.startPrank(OTHER);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.enableIrm(address(0xBBBB));

        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.enableLltv(7e17);

        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.setFee(marketId, 1e16);

        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.setFeeRecipientPositionKey(keccak256("x"));

        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.setMaxStaleness(1 days);

        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.setOwner(address(0xCC));
        vm.stopPrank();
    }

    /// @dev Property 23: Fee Boundary Rejection
    /// Validates: Requirement 15.4
    function test_property23_feeBoundaryRejection() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _createEnabledParams();
        bytes32 marketId = h.createIlmIsolatedMarket(params, 1);

        uint256 tooHigh = IlmIsolatedTypes.MAX_FEE + 1;
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedFeeTooHigh.selector, tooHigh, IlmIsolatedTypes.MAX_FEE));
        h.setFee(marketId, tooHigh);
    }

    /// @dev Property 8: Market module binding round-trip and immutability
    /// Validates: Requirements 20.1, 20.3
    function test_property8_marketModuleBindingRoundTripAndImmutability() public {
        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = _createEnabledParams();
        uint256 moduleId = 123;
        bytes32 marketId = h.createIlmIsolatedMarket(params, moduleId);

        assertEq(h.getMarketModuleId(marketId), moduleId);

        vm.expectRevert(abi.encodeWithSelector(IlmIsolatedMarketAlreadyCreated.selector, marketId));
        h.createIlmIsolatedMarket(params, 999);

        assertEq(h.getMarketModuleId(marketId), moduleId);
    }

    function test_setAuthorization_positionOwnerOnly() public {
        PositionNFT nft = _deployAndConfigurePositionNft();
        uint256 tokenId = nft.mint(OWNER, 1);
        bytes32 positionKey = nft.getPositionKey(tokenId);

        vm.prank(OTHER);
        vm.expectRevert(IlmIsolatedUnauthorized.selector);
        h.setAuthorization(positionKey, OPERATOR, true);
    }

    function _createEnabledParams() internal returns (IlmIsolatedTypes.IlmIsolatedMarketParams memory params) {
        uint256 lltv = 8e17;
        vm.startPrank(OWNER);
        h.enableIrm(address(irm));
        h.enableLltv(lltv);
        vm.stopPrank();

        params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 1,
            collateralPoolId: 2,
            oracle: address(0x1234),
            irm: address(irm),
            lltv: lltv
        });
    }

    function _deployAndConfigurePositionNft() internal returns (PositionNFT nft) {
        nft = new PositionNFT();
        nft.setMinter(address(this));
        h.setPositionNftRaw(address(nft), true);
    }
}
