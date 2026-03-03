// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamTypes} from "src/libraries/MamTypes.sol";
import {LibMamCurveHasher} from "src/libraries/LibMamCurveHasher.sol";

contract LibMamCurveHasherV2PropertyTest is Test {
    bytes32 internal constant CURVE_DOMAIN_SEPARATOR_V1 = keccak256("MAM_CURVE_V1");
    bytes32 internal constant CURVE_DOMAIN_SEPARATOR_V2 = keccak256("MAM_CURVE_V2");

    function testFuzz_curveHashSensitiveToProfileId(
        uint16 profileIdARaw,
        uint16 profileIdBRaw,
        bytes32 profileParams,
        uint96 salt
    ) public {
        uint16 profileIdA = uint16(bound(profileIdARaw, 1, type(uint16).max));
        uint16 profileIdB = uint16(bound(profileIdBRaw, 1, type(uint16).max));
        vm.assume(profileIdA != profileIdB);

        MamTypes.CurveDescriptor memory desc = _descriptor(profileIdA, profileParams, salt);
        bytes32 hashA = LibMamCurveHasher.curveHash(desc);

        desc.profileId = profileIdB;
        bytes32 hashB = LibMamCurveHasher.curveHash(desc);

        assertTrue(hashA != hashB, "profileId must affect hash");
    }

    function testFuzz_curveHashSensitiveToProfileParams(uint16 profileIdRaw, bytes32 paramsA, bytes32 paramsB, uint96 salt)
        public
    {
        uint16 profileId = uint16(bound(profileIdRaw, 1, type(uint16).max));
        vm.assume(paramsA != paramsB);

        MamTypes.CurveDescriptor memory desc = _descriptor(profileId, paramsA, salt);
        bytes32 hashA = LibMamCurveHasher.curveHash(desc);

        desc.profileParams = paramsB;
        bytes32 hashB = LibMamCurveHasher.curveHash(desc);

        assertTrue(hashA != hashB, "profile params must affect hash");
    }

    function testFuzz_curveHashUsesV2DomainSeparator(uint16 profileIdRaw, bytes32 profileParams, uint96 salt) public {
        uint16 profileId = uint16(bound(profileIdRaw, 1, type(uint16).max));
        MamTypes.CurveDescriptor memory desc = _descriptor(profileId, profileParams, salt);
        bytes32 hashV2 = LibMamCurveHasher.curveHash(desc);
        bytes32 expectedV2 = keccak256(abi.encode(CURVE_DOMAIN_SEPARATOR_V2, desc));
        bytes32 hashV1 = keccak256(abi.encode(CURVE_DOMAIN_SEPARATOR_V1, desc));

        assertEq(hashV2, expectedV2, "hash must use V2 domain separator");
        assertTrue(hashV2 != hashV1, "V2 and V1 hashes must differ");
    }

    function _descriptor(uint16 profileId, bytes32 profileParams, uint96 salt)
        internal
        pure
        returns (MamTypes.CurveDescriptor memory desc)
    {
        desc.makerPositionKey = bytes32(uint256(1));
        desc.makerPositionId = 1;
        desc.poolIdA = 10;
        desc.poolIdB = 11;
        desc.tokenA = address(0xA);
        desc.tokenB = address(0xB);
        desc.side = false;
        desc.priceIsQuotePerBase = true;
        desc.maxVolume = 100 ether;
        desc.startPrice = 2e18;
        desc.endPrice = 1e18;
        desc.startTime = 100;
        desc.duration = 1 days;
        desc.generation = 1;
        desc.feeRateBps = 25;
        desc.feeAsset = MamTypes.FeeAsset.TokenIn;
        desc.salt = salt;
        desc.profileId = profileId;
        desc.profileParams = profileParams;
    }
}
