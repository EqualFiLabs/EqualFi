// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IndexToken, IEqualIndexData} from "../../src/equalindex/IndexToken.sol";
import {LibEqualIndex} from "../../src/libraries/LibEqualIndex.sol";

contract IndexMinterMock is IEqualIndexData {
    IEqualIndexData.Index internal indexData;
    mapping(address => uint256) internal vaultBalances;
    mapping(address => uint256) internal feePots;

    function setIndex(IEqualIndexData.Index memory data) external {
        indexData = data;
    }

    function setVaultBalance(address asset, uint256 amount) external {
        vaultBalances[asset] = amount;
    }

    function setFeePot(address asset, uint256 amount) external {
        feePots[asset] = amount;
    }

    function getIndex(uint256) external view returns (IEqualIndexData.Index memory index_) {
        return indexData;
    }

    function getVaultBalance(uint256, address asset) external view returns (uint256) {
        return vaultBalances[asset];
    }

    function getFeePot(uint256, address asset) external view returns (uint256) {
        return feePots[asset];
    }
}

contract IndexTokenGasTest is Test {
    IndexToken internal token;
    IndexMinterMock internal minter;

    address internal assetA = address(0xA11CE);
    address internal assetB = address(0xB0B);

    function setUp() public {
        minter = new IndexMinterMock();

        address[] memory assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
        uint256[] memory bundles = new uint256[](2);
        bundles[0] = 1 ether;
        bundles[1] = 2 ether;

        token = new IndexToken("Index", "IDX", address(minter), assets, bundles, 50, 0);

        uint16[] memory mintFees = new uint16[](2);
        mintFees[0] = 100;
        mintFees[1] = 200;
        uint16[] memory burnFees = new uint16[](2);
        burnFees[0] = 100;
        burnFees[1] = 200;

        IEqualIndexData.Index memory idx = IEqualIndexData.Index({
            assets: assets,
            bundleAmounts: bundles,
            mintFeeBps: mintFees,
            burnFeeBps: burnFees,
            flashFeeBps: 50,
            totalUnits: 0,
            token: address(token),
            paused: false
        });
        minter.setIndex(idx);
        minter.setVaultBalance(assetA, 2 ether);
        minter.setVaultBalance(assetB, 4 ether);
        minter.setFeePot(assetA, 0.2 ether);
        minter.setFeePot(assetB, 0.4 ether);

        vm.prank(address(minter));
        token.mintIndexUnits(address(this), LibEqualIndex.INDEX_SCALE);
    }

    function test_gas_MintIndexUnits() public {
        vm.prank(address(minter));
        vm.resumeGasMetering();
        token.mintIndexUnits(address(this), 1 ether);
    }

    function test_gas_BurnIndexUnits() public {
        vm.prank(address(minter));
        vm.resumeGasMetering();
        token.burnIndexUnits(address(this), 1 ether);
    }

    function test_gas_RecordMintDetails() public {
        address[] memory assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 0.01 ether;
        fees[1] = 0.02 ether;

        vm.prank(address(minter));
        vm.resumeGasMetering();
        token.recordMintDetails(address(this), 1 ether, assets, amounts, fees, 0);
    }

    function test_gas_RecordBurnDetails() public {
        address[] memory assets = new address[](2);
        assets[0] = assetA;
        assets[1] = assetB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 0.01 ether;
        fees[1] = 0.02 ether;

        vm.prank(address(minter));
        vm.resumeGasMetering();
        token.recordBurnDetails(address(this), 1 ether, assets, amounts, fees, 0);
    }

    function test_gas_SetFlashFeeBps() public {
        vm.prank(address(minter));
        vm.resumeGasMetering();
        token.setFlashFeeBps(100);
    }

    function test_gas_AssetsPaginated() public {
        vm.resumeGasMetering();
        token.assetsPaginated(0, 1);
    }

    function test_gas_BundleAmountsPaginated() public {
        vm.resumeGasMetering();
        token.bundleAmountsPaginated(0, 1);
    }

    function test_gas_PreviewMintPaginated() public {
        vm.resumeGasMetering();
        token.previewMintPaginated(LibEqualIndex.INDEX_SCALE, 0, 2);
    }

    function test_gas_PreviewRedeem() public {
        vm.resumeGasMetering();
        token.previewRedeem(LibEqualIndex.INDEX_SCALE);
    }

    function test_gas_PreviewRedeemPaginated() public {
        vm.resumeGasMetering();
        token.previewRedeemPaginated(LibEqualIndex.INDEX_SCALE, 0, 2);
    }

    function test_gas_PreviewFlashLoanPaginated() public {
        vm.resumeGasMetering();
        token.previewFlashLoanPaginated(LibEqualIndex.INDEX_SCALE, 0, 2);
    }

    function test_gas_IsSolvent() public {
        vm.resumeGasMetering();
        token.isSolvent();
    }
}
