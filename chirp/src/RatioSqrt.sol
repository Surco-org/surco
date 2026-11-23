// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Floor sqrt(amount1 / amount0) as a Q64.96 price inside the v4 tick range.
///         The comparison is exact. A shifted integer square root would drift on a high open.
library RatioSqrt {
    error BadPrice();

    function sqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert BadPrice();

        uint160 minP = TickMath.MIN_SQRT_PRICE + 1;
        uint160 maxP = TickMath.MAX_SQRT_PRICE - 1;
        if (_tooHigh(minP, amount1, amount0)) revert BadPrice();
        // MAX itself is not a legal swap limit. A true sqrt at or above it cannot be posted.
        if (!_tooHigh(TickMath.MAX_SQRT_PRICE, amount1, amount0)) revert BadPrice();
        if (!_tooHigh(maxP, amount1, amount0)) return maxP;

        uint160 lo = minP;
        uint160 hi = maxP;
        while (uint256(lo) + 1 < uint256(hi)) {
            uint160 mid = uint160((uint256(lo) + uint256(hi)) >> 1);
            if (_tooHigh(mid, amount1, amount0)) hi = mid;
            else lo = mid;
        }
        return lo;
    }

    /// @dev True when p^2 * amount0 > amount1 << 192. Equal is not too high, so the result floors.
    function _tooHigh(uint160 p, uint256 amount1, uint256 amount0) private pure returns (bool) {
        (uint256 sqHi, uint256 sqLo) = _mul256(uint256(p), uint256(p));
        (uint256 top, uint256 mid, uint256 bot) = _mul512by256(sqHi, sqLo, amount0);
        if (top != 0) return true;

        uint256 rightHi = amount1 >> 64;
        uint256 rightLo = amount1 << 192;
        if (mid != rightHi) return mid > rightHi;
        return bot > rightLo;
    }

    function _mul256(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    function _mul512by256(uint256 hi, uint256 lo, uint256 m)
        private
        pure
        returns (uint256 top, uint256 mid, uint256 bot)
    {
        (uint256 loHi, uint256 loLo) = _mul256(lo, m);
        (uint256 hiHi, uint256 hiLo) = _mul256(hi, m);
        bot = loLo;
        unchecked {
            mid = loHi + hiLo;
            top = hiHi + (mid < loHi ? 1 : 0);
        }
    }
}
