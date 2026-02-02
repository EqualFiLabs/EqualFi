// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibMamMath} from "../src/libraries/LibMamMath.sol";

contract EchidnaMamMath {
    uint256 internal constant WAD = 1e18;
    
    // Bound inputs to realistic WAD values to avoid trivial overflows
    uint256 internal constant MAX_PRICE = 1e36; // 1e18 * 1e18
    uint256 internal constant MAX_TIME = type(uint40).max;

    // ========== ASSERTION TESTS ==========

    /// @notice Price must be bounded by [startPrice, endPrice] (or vice versa)
    function test_price_bounds(uint256 startPrice, uint256 endPrice, uint256 start, uint256 duration, uint256 t) 
        public pure 
    {
        startPrice = startPrice % MAX_PRICE;
        endPrice = endPrice % MAX_PRICE;
        start = start % MAX_TIME;
        duration = duration % MAX_TIME;
        if (duration == 0) duration = 1;
        t = t % MAX_TIME;
        
        uint256 price = LibMamMath.computePrice(startPrice, endPrice, start, duration, t);
        
        if (startPrice <= endPrice) {
            assert(price >= startPrice && price <= endPrice);
        } else {
            assert(price <= startPrice && price >= endPrice);
        }
    }

    /// @notice Price monotonicity: For falling curve, p(t) >= p(t+k)
    function test_price_monotonicity_falling(uint256 startPrice, uint256 endPrice, uint256 start, uint256 duration, uint256 t, uint256 k) 
        public pure 
    {
        startPrice = startPrice % MAX_PRICE;
        endPrice = endPrice % MAX_PRICE;
        start = start % MAX_TIME;
        duration = duration % MAX_TIME;
        if (duration == 0) duration = 1;
        t = t % MAX_TIME;
        k = k % duration; // Step within limits
        
        if (startPrice <= endPrice) return; // Only test falling curves here
        
        uint256 p1 = LibMamMath.computePrice(startPrice, endPrice, start, duration, t);
        uint256 p2 = LibMamMath.computePrice(startPrice, endPrice, start, duration, t + k);
        
        assert(p1 >= p2);
    }

    /// @notice AmountIn calculation is linear with respect to fill amount
    function test_amountIn_linear(uint256 baseFill1, uint256 baseFill2, uint256 price) public pure {
        baseFill1 = baseFill1 % MAX_PRICE;
        baseFill2 = baseFill2 % MAX_PRICE;
        price = price % MAX_PRICE;
        
        uint256 in1 = LibMamMath.amountInForFill(baseFill1, price);
        uint256 in2 = LibMamMath.amountInForFill(baseFill2, price);
        uint256 inSum = LibMamMath.amountInForFill(baseFill1 + baseFill2, price);
        
        // Due to floor division: floor(a) + floor(b) <= floor(a+b)
        // So inSum >= in1 + in2
        assert(inSum >= in1 + in2);
        
        // Difference should be small
        assert(inSum <= in1 + in2 + 1);
    }
}
