// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibEqualIndexLending} from "../../src/libraries/LibEqualIndexLending.sol";

contract LibEqualIndexLendingHarness {
    error InvalidNarrowCast();

    function setConfig(
        uint256 indexId,
        uint256 ltvBps,
        uint256 originationFeeBps,
        uint256 minDuration,
        uint256 maxDuration
    ) external {
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        ls.lendingConfigs[indexId] = LibEqualIndexLending.LendingConfig({
            ltvBps: _toUint16(ltvBps),
            originationFeeBps: _toUint16(originationFeeBps),
            minDuration: _toUint40(minDuration),
            maxDuration: _toUint40(maxDuration)
        });
    }

    function setLoan(
        uint256 loanId,
        bytes32 positionKey,
        uint256 indexId,
        uint256 collateralUnits,
        uint256 ltvBps,
        uint256 maturity
    ) external {
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        ls.loans[loanId] = LibEqualIndexLending.IndexLoan({
            positionKey: positionKey,
            indexId: indexId,
            collateralUnits: collateralUnits,
            ltvBps: _toUint16(ltvBps),
            maturity: _toUint40(maturity)
        });
    }

    function setOutstandingPrincipal(uint256 indexId, address asset, uint256 amount) external {
        LibEqualIndexLending.s().outstandingPrincipal[indexId][asset] = amount;
    }

    function setLockedCollateralUnits(uint256 indexId, uint256 amount) external {
        LibEqualIndexLending.s().lockedCollateralUnits[indexId] = amount;
    }

    function setNextLoanId(uint256 nextLoanId) external {
        LibEqualIndexLending.s().nextLoanId = nextLoanId;
    }

    function setBorrowFeeTiers(
        uint256 indexId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external {
        if (minCollateralUnits.length != flatFeeNative.length) revert InvalidNarrowCast();
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        delete ls.borrowFeeTiers[indexId];
        for (uint256 i = 0; i < minCollateralUnits.length; i++) {
            ls.borrowFeeTiers[indexId].push(
                LibEqualIndexLending.BorrowFeeTier({
                    minCollateralUnits: minCollateralUnits[i],
                    flatFeeNative: flatFeeNative[i]
                })
            );
        }
    }

    function getConfig(uint256 indexId) external view returns (LibEqualIndexLending.LendingConfig memory) {
        return LibEqualIndexLending.s().lendingConfigs[indexId];
    }

    function getLoan(uint256 loanId) external view returns (LibEqualIndexLending.IndexLoan memory) {
        return LibEqualIndexLending.s().loans[loanId];
    }

    function getOutstandingPrincipal(uint256 indexId, address asset) external view returns (uint256) {
        return LibEqualIndexLending.s().outstandingPrincipal[indexId][asset];
    }

    function getLockedCollateralUnits(uint256 indexId) external view returns (uint256) {
        return LibEqualIndexLending.s().lockedCollateralUnits[indexId];
    }

    function getNextLoanId() external view returns (uint256) {
        return LibEqualIndexLending.s().nextLoanId;
    }

    function getBorrowFeeTierCount(uint256 indexId) external view returns (uint256) {
        return LibEqualIndexLending.s().borrowFeeTiers[indexId].length;
    }

    function getBorrowFeeTier(uint256 indexId, uint256 tierIndex)
        external
        view
        returns (uint256 minCollateralUnits, uint256 flatFeeNative)
    {
        LibEqualIndexLending.BorrowFeeTier storage tier = LibEqualIndexLending.s().borrowFeeTiers[indexId][tierIndex];
        return (tier.minCollateralUnits, tier.flatFeeNative);
    }

    function getEconomicBalance(uint256 indexId, address asset, uint256 vaultBalance) external view returns (uint256) {
        return LibEqualIndexLending.getEconomicBalance(indexId, asset, vaultBalance);
    }

    function emitLoanCreated(
        uint256 loanId,
        bytes32 positionKey,
        uint256 indexId,
        uint256 collateralUnits,
        uint256 ltvBps,
        uint256 maturity
    ) external {
        emit LibEqualIndexLending.LoanCreated(loanId, positionKey, indexId, collateralUnits, _toUint16(ltvBps), _toUint40(maturity));
    }

    function emitLoanAssetDelta(uint256 loanId, address borrowAsset, uint256 principal, uint256 fee, bool outgoing)
        external
    {
        emit LibEqualIndexLending.LoanAssetDelta(loanId, borrowAsset, principal, fee, outgoing);
    }

    function emitLoanRepaid(uint256 loanId, uint256 indexId) external {
        emit LibEqualIndexLending.LoanRepaid(loanId, indexId);
    }

    function emitLoanExtended(uint256 loanId, uint256 newMaturity, uint256 fee) external {
        emit LibEqualIndexLending.LoanExtended(loanId, _toUint40(newMaturity), fee);
    }

    function emitLoanRecovered(uint256 loanId, uint256 indexId, uint256 collateralUnits, uint256 writtenOffPrincipal)
        external
    {
        emit LibEqualIndexLending.LoanRecovered(loanId, indexId, collateralUnits, writtenOffPrincipal);
    }

    function emitLendingConfigured(
        uint256 indexId,
        uint256 ltvBps,
        uint256 originationFeeBps,
        uint256 minDuration,
        uint256 maxDuration
    ) external {
        emit LibEqualIndexLending.LendingConfigured(
            indexId, _toUint16(ltvBps), _toUint16(originationFeeBps), _toUint40(minDuration), _toUint40(maxDuration)
        );
    }

    function emitBorrowFeeTiersConfigured(
        uint256 indexId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external {
        emit LibEqualIndexLending.BorrowFeeTiersConfigured(indexId, minCollateralUnits, flatFeeNative);
    }

    function emitBorrowFlatFeePaid(uint256 loanId, uint256 indexId, uint256 collateralUnits, uint256 feeNative) external {
        emit LibEqualIndexLending.BorrowFlatFeePaid(loanId, indexId, collateralUnits, feeNative);
    }

    function emitLoanExtendFlatFeePaid(
        uint256 loanId,
        uint256 indexId,
        uint256 collateralUnits,
        uint256 addedDuration,
        uint256 feeNative
    ) external {
        emit LibEqualIndexLending.LoanExtendFlatFeePaid(
            loanId, indexId, collateralUnits, _toUint40(addedDuration), feeNative
        );
    }

    function _toUint16(uint256 value) private pure returns (uint16) {
        if (value > type(uint16).max) revert InvalidNarrowCast();
        return uint16(value);
    }

    function _toUint40(uint256 value) private pure returns (uint40) {
        if (value > type(uint40).max) revert InvalidNarrowCast();
        return uint40(value);
    }
}

contract LibEqualIndexLendingTest is Test {
    event LoanCreated(
        uint256 indexed loanId,
        bytes32 indexed positionKey,
        uint256 indexed indexId,
        uint256 collateralUnits,
        uint16 ltvBps,
        uint40 maturity
    );
    event LoanAssetDelta(
        uint256 indexed loanId,
        address indexed borrowAsset,
        uint256 principal,
        uint256 fee,
        bool outgoing
    );
    event LoanRepaid(uint256 indexed loanId, uint256 indexed indexId);
    event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 totalFee);
    event LoanRecovered(uint256 indexed loanId, uint256 indexed indexId, uint256 collateralUnits, uint256 writtenOffPrincipalTotal);
    event LendingConfigured(
        uint256 indexed indexId, uint16 ltvBps, uint16 originationFeeBps, uint40 minDuration, uint40 maxDuration
    );
    event BorrowFeeTiersConfigured(uint256 indexed indexId, uint256[] minCollateralUnits, uint256[] flatFeeNative);
    event BorrowFlatFeePaid(
        uint256 indexed loanId, uint256 indexed indexId, uint256 collateralUnits, uint256 feeNative
    );
    event LoanExtendFlatFeePaid(
        uint256 indexed loanId,
        uint256 indexed indexId,
        uint256 collateralUnits,
        uint40 addedDuration,
        uint256 feeNative
    );

    LibEqualIndexLendingHarness internal h;

    function setUp() public {
        h = new LibEqualIndexLendingHarness();
    }

    function test_storageRoundTrip_ConfigLoanAndTrackers() public {
        uint256 indexId = 3;
        uint256 loanId = 7;
        bytes32 positionKey = keccak256("pk");
        address asset = address(0xBEEF);

        h.setConfig(indexId, 9200, 75, 1 days, 30 days);
        h.setLoan(loanId, positionKey, indexId, 10 ether, 9200, block.timestamp + 7 days);
        h.setOutstandingPrincipal(indexId, asset, 1234);
        h.setLockedCollateralUnits(indexId, 22 ether);
        h.setNextLoanId(11);
        uint256[] memory mins = new uint256[](2);
        uint256[] memory fees = new uint256[](2);
        mins[0] = 1 ether;
        mins[1] = 5 ether;
        fees[0] = 0.001 ether;
        fees[1] = 0.005 ether;
        h.setBorrowFeeTiers(indexId, mins, fees);

        LibEqualIndexLending.LendingConfig memory cfg = h.getConfig(indexId);
        assertEq(cfg.ltvBps, 9200);
        assertEq(cfg.originationFeeBps, 75);
        assertEq(cfg.minDuration, 1 days);
        assertEq(cfg.maxDuration, 30 days);

        LibEqualIndexLending.IndexLoan memory loan = h.getLoan(loanId);
        assertEq(loan.positionKey, positionKey);
        assertEq(loan.indexId, indexId);
        assertEq(loan.collateralUnits, 10 ether);
        assertEq(loan.ltvBps, 9200);
        assertEq(loan.maturity, uint40(block.timestamp + 7 days));

        assertEq(h.getOutstandingPrincipal(indexId, asset), 1234);
        assertEq(h.getLockedCollateralUnits(indexId), 22 ether);
        assertEq(h.getNextLoanId(), 11);
        assertEq(h.getBorrowFeeTierCount(indexId), 2);
        (uint256 min0, uint256 fee0) = h.getBorrowFeeTier(indexId, 0);
        assertEq(min0, 1 ether);
        assertEq(fee0, 0.001 ether);
    }

    function test_getEconomicBalance_AddsOutstandingPrincipal() public {
        uint256 indexId = 1;
        address asset = address(0xABCD);

        h.setOutstandingPrincipal(indexId, asset, 45 ether);

        uint256 economic = h.getEconomicBalance(indexId, asset, 100 ether);
        assertEq(economic, 145 ether);

        uint256 otherEconomic = h.getEconomicBalance(indexId, address(0xD00D), 100 ether);
        assertEq(otherEconomic, 100 ether);
    }

    function test_emitsAllDeclaredEvents() public {
        bytes32 positionKey = keccak256("position");
        address asset = address(0xCAFE);

        vm.expectEmit(true, true, true, true);
        emit LoanCreated(1, positionKey, 2, 5, 4, 123);
        h.emitLoanCreated(1, positionKey, 2, 5, 4, 123);

        vm.expectEmit(true, true, false, true);
        emit LoanAssetDelta(1, asset, 4, 1, true);
        h.emitLoanAssetDelta(1, asset, 4, 1, true);

        vm.expectEmit(true, true, false, true);
        emit LoanRepaid(1, 2);
        h.emitLoanRepaid(1, 2);

        vm.expectEmit(true, false, false, true);
        emit LoanExtended(1, 456, 2);
        h.emitLoanExtended(1, 456, 2);

        vm.expectEmit(true, true, false, true);
        emit LoanRecovered(1, 2, 5, 4);
        h.emitLoanRecovered(1, 2, 5, 4);

        vm.expectEmit(true, false, false, true);
        emit LendingConfigured(2, 9000, 50, 1 days, 30 days);
        h.emitLendingConfigured(2, 9000, 50, 1 days, 30 days);

        uint256[] memory mins = new uint256[](2);
        uint256[] memory fees = new uint256[](2);
        mins[0] = 1 ether;
        mins[1] = 3 ether;
        fees[0] = 0.001 ether;
        fees[1] = 0.003 ether;

        vm.expectEmit(true, false, false, true);
        emit BorrowFeeTiersConfigured(2, mins, fees);
        h.emitBorrowFeeTiersConfigured(2, mins, fees);

        vm.expectEmit(true, true, false, true);
        emit BorrowFlatFeePaid(9, 2, 1 ether, 0.001 ether);
        h.emitBorrowFlatFeePaid(9, 2, 1 ether, 0.001 ether);

        vm.expectEmit(true, true, false, true);
        emit LoanExtendFlatFeePaid(9, 2, 1 ether, 1 days, 0.001 ether);
        h.emitLoanExtendFlatFeePaid(9, 2, 1 ether, 1 days, 0.001 ether);
    }
}
