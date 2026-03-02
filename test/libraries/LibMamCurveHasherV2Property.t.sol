// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamTypes} from "src/libraries/MamTypes.sol";
import {LibMamCurveHasher} from "src/libraries/LibMamCurveHasher.sol";

contract LibMamCurveHasherV2PropertyTest is Test {
    bytes32 internal constant CURVE_DOMAIN_SEPARATOR_V1 = keccak256("MAM_CURVE_V1");
    bytes32 internal constant CURVE_DOMAIN_SEPARATOR_V2 = keccak256("MAM_CURVE_V2");

    function testFuzz_curveHashSensitiveToProfileAddress(address profileA, address profileB, bytes32 profileParams, uint96 salt)
        public
    {
        vm.assume(profileA != profileB);

        MamTypes.CurveDescriptor memory desc = _descriptor(profileA, profileParams, salt);
        bytes32 hashA = LibMamCurveHasher.curveHash(desc);

        desc.profile = profileB;
        bytes32 hashB = LibMamCurveHasher.curveHash(desc);

        assertTrue(hashA != hashB, "profile address must affect hash");
    }

    function testFuzz_curveHashSensitiveToProfileParams(address profile, bytes32 paramsA, bytes32 paramsB, uint96 salt)
        public
    {
        vm.assume(paramsA != paramsB);

        MamTypes.CurveDescriptor memory desc = _descriptor(profile, paramsA, salt);
        bytes32 hashA = LibMamCurveHasher.curveHash(desc);

        desc.profileParams = paramsB;
        bytes32 hashB = LibMamCurveHasher.curveHash(desc);

        assertTrue(hashA != hashB, "profile params must affect hash");
    }

    function testFuzz_curveHashUsesV2DomainSeparator(address profile, bytes32 profileParams, uint96 salt)
        public
    {
        MamTypes.CurveDescriptor memory desc = _descriptor(profile, profileParams, salt);
        bytes32 hashV2 = LibMamCurveHasher.curveHash(desc);
        bytes32 expectedV2 = keccak256(abi.encode(CURVE_DOMAIN_SEPARATOR_V2, desc));
        bytes32 hashV1 = keccak256(abi.encode(CURVE_DOMAIN_SEPARATOR_V1, desc));

        assertEq(hashV2, expectedV2, "hash must use V2 domain separator");
        assertTrue(hashV2 != hashV1, "V2 and V1 hashes must differ");
    }

    function _descriptor(address profile, bytes32 profileParams, uint96 salt)
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
        desc.profile = profile;
        desc.profileParams = profileParams;
    }
}
