// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MamTypes} from "src/libraries/MamTypes.sol";
import {LibDerivativeStorage} from "src/libraries/LibDerivativeStorage.sol";
import {ICurveProfile} from "src/interfaces/ICurveProfile.sol";
import "src/libraries/MamCurveErrors.sol";

contract MockCurveProfile is ICurveProfile {
    function computePrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 duration,
        uint256 currentTime,
        bytes32 profileParams
    ) external pure returns (uint256 price) {
        return startPrice + endPrice + startTime + duration + currentTime + uint256(profileParams);
    }
}

contract MamCurveTask1Harness {
    function setCurveProfileData(uint256 curveId, address profile, bytes32 profileParams) external {
        LibDerivativeStorage.derivativeStorage().curveProfileData[curveId] =
            LibDerivativeStorage.CurveProfileData({profile: profile, profileParams: profileParams});
    }

    function getCurveProfileData(uint256 curveId) external view returns (address profile, bytes32 profileParams) {
        LibDerivativeStorage.CurveProfileData storage data = LibDerivativeStorage.derivativeStorage().curveProfileData[curveId];
        return (data.profile, data.profileParams);
    }

    function setApprovedProfile(address profile, bool approved) external {
        LibDerivativeStorage.derivativeStorage().approvedProfiles[profile] = approved;
    }

    function isApprovedProfile(address profile) external view returns (bool) {
        return LibDerivativeStorage.derivativeStorage().approvedProfiles[profile];
    }

    function revertGenerationMismatch(uint32 expected, uint32 actual) external pure {
        revert MamCurve_GenerationMismatch(expected, actual);
    }

    function revertCommitmentMismatch(bytes32 expected, bytes32 actual) external pure {
        revert MamCurve_CommitmentMismatch(expected, actual);
    }

    function revertProfileNotApproved(address profile) external pure {
        revert MamCurve_ProfileNotApproved(profile);
    }
}

contract MamCurveTask1ModelsAndErrorsTest is Test {
    MamCurveTask1Harness internal harness;
    MockCurveProfile internal profile;

    function setUp() public {
        harness = new MamCurveTask1Harness();
        profile = new MockCurveProfile();
    }

    function testCurveDescriptorIncludesProfileFields() public {
        MamTypes.CurveDescriptor memory desc;
        desc.profile = address(profile);
        desc.profileParams = bytes32(uint256(777));

        assertEq(desc.profile, address(profile));
        assertEq(uint256(desc.profileParams), 777);
    }

    function testCurveUpdateParamsIncludesProfileFields() public {
        MamTypes.CurveUpdateParams memory params;
        params.updateProfile = true;
        params.profile = address(profile);
        params.updateProfileParams = true;
        params.profileParams = bytes32(uint256(888));

        assertTrue(params.updateProfile);
        assertEq(params.profile, address(profile));
        assertTrue(params.updateProfileParams);
        assertEq(uint256(params.profileParams), 888);
    }

    function testCurveFillViewIncludesProfileFields() public {
        MamTypes.CurveFillView memory viewData;
        viewData.profile = address(profile);
        viewData.profileParams = bytes32(uint256(999));

        assertEq(viewData.profile, address(profile));
        assertEq(uint256(viewData.profileParams), 999);
    }

    function testCurveProfileDataStorageRoundTrip() public {
        uint256 curveId = 42;
        bytes32 params = bytes32(uint256(123456));
        harness.setCurveProfileData(curveId, address(profile), params);

        (address storedProfile, bytes32 storedParams) = harness.getCurveProfileData(curveId);
        assertEq(storedProfile, address(profile));
        assertEq(storedParams, params);
    }

    function testApprovedProfilesStorageRoundTrip() public {
        assertFalse(harness.isApprovedProfile(address(profile)));
        harness.setApprovedProfile(address(profile), true);
        assertTrue(harness.isApprovedProfile(address(profile)));
        harness.setApprovedProfile(address(profile), false);
        assertFalse(harness.isApprovedProfile(address(profile)));
    }

    function testGenerationMismatchError() public {
        vm.expectRevert(abi.encodeWithSelector(MamCurve_GenerationMismatch.selector, uint32(3), uint32(4)));
        harness.revertGenerationMismatch(3, 4);
    }

    function testCommitmentMismatchError() public {
        bytes32 expected = bytes32(uint256(11));
        bytes32 actual = bytes32(uint256(12));
        vm.expectRevert(abi.encodeWithSelector(MamCurve_CommitmentMismatch.selector, expected, actual));
        harness.revertCommitmentMismatch(expected, actual);
    }

    function testProfileNotApprovedError() public {
        vm.expectRevert(abi.encodeWithSelector(MamCurve_ProfileNotApproved.selector, address(profile)));
        harness.revertProfileNotApproved(address(profile));
    }

    function testICurveProfileSignatureAndStaticcall() public {
        bytes4 expectedSelector = bytes4(keccak256("computePrice(uint256,uint256,uint256,uint256,uint256,bytes32)"));
        assertEq(ICurveProfile.computePrice.selector, expectedSelector);

        (bool ok, bytes memory ret) = address(profile).staticcall(
            abi.encodeCall(
                ICurveProfile.computePrice,
                (1, 2, 3, 4, 5, bytes32(uint256(6)))
            )
        );
        assertTrue(ok);
        uint256 price = abi.decode(ret, (uint256));
        assertEq(price, 21);
    }
}
