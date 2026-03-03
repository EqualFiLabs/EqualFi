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
    function setCurveProfileData(uint256 curveId, uint16 profileId, bytes32 profileParams) external {
        LibDerivativeStorage.derivativeStorage().curveProfileData[curveId] =
            LibDerivativeStorage.CurveProfileData({profileId: profileId, profileParams: profileParams});
    }

    function getCurveProfileData(uint256 curveId) external view returns (uint16 profileId, bytes32 profileParams) {
        LibDerivativeStorage.CurveProfileData storage data = LibDerivativeStorage.derivativeStorage().curveProfileData[curveId];
        return (data.profileId, data.profileParams);
    }

    function setCurveProfile(uint16 profileId, address impl, uint32 flags, bool approved) external {
        LibDerivativeStorage.derivativeStorage().curveProfiles[profileId] = LibDerivativeStorage.CurveProfileRegistryEntry({
            impl: impl,
            flags: flags,
            approved: approved
        });
    }

    function getCurveProfile(uint16 profileId)
        external
        view
        returns (address impl, uint32 flags, bool approved)
    {
        LibDerivativeStorage.CurveProfileRegistryEntry storage entry =
            LibDerivativeStorage.derivativeStorage().curveProfiles[profileId];
        return (entry.impl, entry.flags, entry.approved);
    }

    function revertGenerationMismatch(uint32 expected, uint32 actual) external pure {
        revert MamCurve_GenerationMismatch(expected, actual);
    }

    function revertCommitmentMismatch(bytes32 expected, bytes32 actual) external pure {
        revert MamCurve_CommitmentMismatch(expected, actual);
    }

    function revertProfileNotApproved(uint16 profileId) external pure {
        revert MamCurve_ProfileNotApproved(profileId);
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
        desc.profileId = 7;
        desc.profileParams = bytes32(uint256(777));

        assertEq(desc.profileId, 7);
        assertEq(uint256(desc.profileParams), 777);
    }

    function testCurveUpdateParamsIncludesProfileFields() public {
        MamTypes.CurveUpdateParams memory params;
        params.updateProfile = true;
        params.profileId = 8;
        params.updateProfileParams = true;
        params.profileParams = bytes32(uint256(888));

        assertTrue(params.updateProfile);
        assertEq(params.profileId, 8);
        assertTrue(params.updateProfileParams);
        assertEq(uint256(params.profileParams), 888);
    }

    function testCurveFillViewIncludesProfileFields() public {
        MamTypes.CurveFillView memory viewData;
        viewData.profileId = 9;
        viewData.profileParams = bytes32(uint256(999));

        assertEq(viewData.profileId, 9);
        assertEq(uint256(viewData.profileParams), 999);
    }

    function testCurveProfileDataStorageRoundTrip() public {
        uint256 curveId = 42;
        bytes32 params = bytes32(uint256(123456));
        harness.setCurveProfileData(curveId, 10, params);

        (uint16 storedProfileId, bytes32 storedParams) = harness.getCurveProfileData(curveId);
        assertEq(storedProfileId, 10);
        assertEq(storedParams, params);
    }

    function testProfileRegistryStorageRoundTrip() public {
        (address impl0,, bool approved0) = harness.getCurveProfile(11);
        assertEq(impl0, address(0));
        assertFalse(approved0);

        harness.setCurveProfile(11, address(profile), 77, true);
        (address impl1, uint32 flags1, bool approved1) = harness.getCurveProfile(11);
        assertEq(impl1, address(profile));
        assertEq(flags1, 77);
        assertTrue(approved1);

        harness.setCurveProfile(11, address(profile), 77, false);
        (, , bool approved2) = harness.getCurveProfile(11);
        assertFalse(approved2);
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
        vm.expectRevert(abi.encodeWithSelector(MamCurve_ProfileNotApproved.selector, uint16(12)));
        harness.revertProfileNotApproved(12);
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
