// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

contract EchidnaValidationLogic {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    // ========== COPIED LOGIC ==========
    // Copied from ValidationFlowLib.sol because original is private

    function _intersectValidationData(uint256 acc, uint256 next) internal pure returns (uint256) {
        (address authA, uint48 untilA, uint48 afterA) = _parseValidationData(acc);
        (address authB, uint48 untilB, uint48 afterB) = _parseValidationData(next);

        if (authA == address(1) || authB == address(1)) {
            return SIG_VALIDATION_FAILED;
        }

        if (authA == address(0)) {
            authA = authB;
        } else if (authB != address(0) && authA != authB) {
            return SIG_VALIDATION_FAILED;
        }

        if (untilA == 0) {
            untilA = type(uint48).max;
        }
        if (untilB == 0) {
            untilB = type(uint48).max;
        }

        uint48 until = untilA < untilB ? untilA : untilB;
        uint48 after_ = afterA > afterB ? afterA : afterB;

        if (until == type(uint48).max) {
            until = 0;
        }

        return _packValidationData(authA, until, after_);
    }

    function _parseValidationData(uint256 data) internal pure returns (address authorizer, uint48 validUntil, uint48 validAfter) {
        authorizer = address(uint160(data));
        validUntil = uint48(data >> 160);
        validAfter = uint48(data >> 208);
    }

    function _packValidationData(address authorizer, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return uint256(uint160(authorizer)) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    // ========== ASSERTION TESTS ==========

    function test_commutativity(uint256 a, uint256 b) public pure {
        uint256 res1 = _intersectValidationData(a, b);
        uint256 res2 = _intersectValidationData(b, a);
        assert(res1 == res2);
    }

    function test_idempotence(uint256 a) public pure {
        uint256 res = _intersectValidationData(a, a);
        
        if (res == a) return;
        
        // Handle normalization: type(uint48).max becomes 0
        (, uint48 untilA, ) = _parseValidationData(a);
        (, uint48 untilRes, ) = _parseValidationData(res);
        
        if (untilA == type(uint48).max && untilRes == 0) {
            // Check other fields match
            (address authA, , uint48 afterA) = _parseValidationData(a);
            (address authRes, , uint48 afterRes) = _parseValidationData(res);
            assert(authA == authRes && afterA == afterRes);
            return;
        }
        
        assert(false); // Fail if not normalization
    }

    function test_time_restrictions(uint256 a, uint256 b) public pure {
        uint256 res = _intersectValidationData(a, b);
        if (res == SIG_VALIDATION_FAILED) return;

        (,, uint48 afterA) = _parseValidationData(a);
        (,, uint48 afterB) = _parseValidationData(b);
        (,, uint48 afterRes) = _parseValidationData(res);

        // Result start time must be max(startA, startB)
        assert(afterRes >= afterA);
        assert(afterRes >= afterB);
        
        // Check end time
        (, uint48 untilA,) = _parseValidationData(a);
        (, uint48 untilB,) = _parseValidationData(b);
        (, uint48 untilRes,) = _parseValidationData(res);
        
        // 0 means type(uint48).max
        uint48 effectiveUntilA = untilA == 0 ? type(uint48).max : untilA;
        uint48 effectiveUntilB = untilB == 0 ? type(uint48).max : untilB;
        uint48 effectiveUntilRes = untilRes == 0 ? type(uint48).max : untilRes;
        
        assert(effectiveUntilRes <= effectiveUntilA);
        assert(effectiveUntilRes <= effectiveUntilB);
    }

    function test_authorizer_conflict(uint256 a, uint256 b) public pure {
        (address authA,,) = _parseValidationData(a);
        (address authB,,) = _parseValidationData(b);
        
        uint256 res = _intersectValidationData(a, b);
        
        if (authA != address(0) && authB != address(0) && authA != authB) {
            // Conflict must result in failure
            assert(res == SIG_VALIDATION_FAILED);
        }
    }
    
    function test_failure_propagation(uint256 a) public pure {
        // If one input is failure, result is failure
        // Wait, SIG_VALIDATION_FAILED is 1. 
        // address(1) is failure marker in logic: if (authA == address(1)).
        // address(1) corresponds to 1.
        
        uint256 failure = SIG_VALIDATION_FAILED;
        uint256 res = _intersectValidationData(a, failure);
        
        assert(res == SIG_VALIDATION_FAILED);
    }
}
