// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IEqualIndexFlashBorrower {
    /// @notice Callback invoked by EqualIndex after transferring loaned assets.
    /// @param initiator msg.sender of the flashLoan call
    /// @param indexId identifier of the index being borrowed
    /// @param assets ordered list of assets matching the index bundle
    /// @param amounts principal loan amounts per asset
    /// @param fees fee amounts owed per asset
    /// @param data arbitrary calldata passed through
    function onEqualIndexFlashLoan(
        address initiator,
        uint256 indexId,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}
