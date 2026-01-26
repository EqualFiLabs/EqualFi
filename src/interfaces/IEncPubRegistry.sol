// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IEncPubRegistry {
    event KeyRegistered(address indexed owner, bytes encPub);

    function registerEncPub(bytes calldata encPub) external;
    function getEncPub(address owner) external view returns (bytes memory);
    function isRegistered(address owner) external view returns (bool);
}
