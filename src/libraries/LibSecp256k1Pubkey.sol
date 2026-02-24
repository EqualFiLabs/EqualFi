// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Shared compressed secp256k1 pubkey validator.
library LibSecp256k1Pubkey {
    uint256 internal constant SECP_P =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant SECP_SQRT_EXP =
        0x3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C;

    function isValidCompressedPubkey(bytes calldata pubkey) internal pure returns (bool) {
        if (pubkey.length != 33) return false;
        bytes1 prefix = pubkey[0];
        if (prefix != 0x02 && prefix != 0x03) return false;

        bytes32 body;
        assembly {
            body := calldataload(add(pubkey.offset, 1))
        }
        uint256 x = uint256(body);
        if (x == 0 || x >= SECP_P) return false;

        uint256 rhs = addmod(mulmod(mulmod(x, x, SECP_P), x, SECP_P), 7, SECP_P);
        uint256 y = _modSqrt(rhs);
        if (mulmod(y, y, SECP_P) != rhs) return false;

        bool yOdd = (y & 1) == 1;
        if ((prefix == 0x02 && yOdd) || (prefix == 0x03 && !yOdd)) {
            y = SECP_P - y;
            yOdd = !yOdd;
        }
        if ((prefix == 0x02 && yOdd) || (prefix == 0x03 && !yOdd)) return false;

        return true;
    }

    function _modSqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        return _expMod(x, SECP_SQRT_EXP, SECP_P);
    }

    function _expMod(uint256 base, uint256 exponent, uint256 modulus) private pure returns (uint256 result) {
        if (modulus == 1) return 0;
        result = 1;
        base = base % modulus;
        while (exponent > 0) {
            if (exponent & 1 == 1) {
                result = mulmod(result, base, modulus);
            }
            base = mulmod(base, base, modulus);
            exponent >>= 1;
        }
        return result;
    }
}
