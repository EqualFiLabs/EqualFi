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
        address borrowAsset,
        uint256 collateralUnits,
        uint256 principal,
        uint256 maturity
    ) external {
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        ls.loans[loanId] = LibEqualIndexLending.IndexLoan({
            positionKey: positionKey,
            indexId: indexId,
            borrowAsset: borrowAsset,
            collateralUnits: collateralUnits,
            principal: principal,
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

    function getEconomicBalance(uint256 indexId, address asset, uint256 vaultBalance) external view returns (uint256) {
        return LibEqualIndexLending.getEconomicBalance(indexId, asset, vaultBalance);
    }

    function emitLoanCreated(
        uint256 loanId,
        bytes32 positionKey,
        uint256 indexId,
        address borrowAsset,
        uint256 collateralUnits,
        uint256 principal,
        uint256 maturity,
        uint256 fee
    ) external {
        emit LibEqualIndexLending.LoanCreated(
            loanId, positionKey, indexId, borrowAsset, collateralUnits, principal, _toUint40(maturity), fee
        );
    }

    function emitLoanRepaid(uint256 loanId, uint256 indexId, address borrowAsset, uint256 principal) external {
        emit LibEqualIndexLending.LoanRepaid(loanId, indexId, borrowAsset, principal);
    }

    function emitLoanExtended(uint256 loanId, uint256 newMaturity, uint256 fee) external {
        emit LibEqualIndexLending.LoanExtended(loanId, _toUint40(newMaturity), fee);
    }

    function emitLoanRecovered(
        uint256 loanId,
        uint256 indexId,
        address borrowAsset,
        uint256 collateralUnits,
        uint256 writtenOffPrincipal
    ) external {
        emit LibEqualIndexLending.LoanRecovered(loanId, indexId, borrowAsset, collateralUnits, writtenOffPrincipal);
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
        address borrowAsset,
        uint256 collateralUnits,
        uint256 principal,
        uint40 maturity,
        uint256 fee
    );
    event LoanRepaid(uint256 indexed loanId, uint256 indexed indexId, address borrowAsset, uint256 principal);
    event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 fee);
    event LoanRecovered(
        uint256 indexed loanId,
        uint256 indexed indexId,
        address borrowAsset,
        uint256 collateralUnits,
        uint256 writtenOffPrincipal
    );
    event LendingConfigured(
        uint256 indexed indexId, uint16 ltvBps, uint16 originationFeeBps, uint40 minDuration, uint40 maxDuration
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
        h.setLoan(loanId, positionKey, indexId, asset, 10 ether, 9 ether, block.timestamp + 7 days);
        h.setOutstandingPrincipal(indexId, asset, 1234);
        h.setLockedCollateralUnits(indexId, 22 ether);
        h.setNextLoanId(11);

        LibEqualIndexLending.LendingConfig memory cfg = h.getConfig(indexId);
        assertEq(cfg.ltvBps, 9200);
        assertEq(cfg.originationFeeBps, 75);
        assertEq(cfg.minDuration, 1 days);
        assertEq(cfg.maxDuration, 30 days);

        LibEqualIndexLending.IndexLoan memory loan = h.getLoan(loanId);
        assertEq(loan.positionKey, positionKey);
        assertEq(loan.indexId, indexId);
        assertEq(loan.borrowAsset, asset);
        assertEq(loan.collateralUnits, 10 ether);
        assertEq(loan.principal, 9 ether);
        assertEq(loan.maturity, uint40(block.timestamp + 7 days));

        assertEq(h.getOutstandingPrincipal(indexId, asset), 1234);
        assertEq(h.getLockedCollateralUnits(indexId), 22 ether);
        assertEq(h.getNextLoanId(), 11);
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
        emit LoanCreated(1, positionKey, 2, asset, 5, 4, 123, 1);
        h.emitLoanCreated(1, positionKey, 2, asset, 5, 4, 123, 1);

        vm.expectEmit(true, true, false, true);
        emit LoanRepaid(1, 2, asset, 4);
        h.emitLoanRepaid(1, 2, asset, 4);

        vm.expectEmit(true, false, false, true);
        emit LoanExtended(1, 456, 2);
        h.emitLoanExtended(1, 456, 2);

        vm.expectEmit(true, true, false, true);
        emit LoanRecovered(1, 2, asset, 5, 4);
        h.emitLoanRecovered(1, 2, asset, 5, 4);

        vm.expectEmit(true, false, false, true);
        emit LendingConfigured(2, 9000, 50, 1 days, 30 days);
        h.emitLendingConfigured(2, 9000, 50, 1 days, 30 days);
    }
}
