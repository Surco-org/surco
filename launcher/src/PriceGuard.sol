// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IWell} from "./interfaces/IWell.sol";
import {IPump} from "./interfaces/IPump.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {CBETH_WELL, V3_WETH_CBETH_POOL, V3_TWAP_SECONDS, WELL_FEE_BPS} from "./Constants.sol";

/// Quotes that a same-transaction trade cannot move: the v3 pool's 30-minute TWAP, and the cbETH well pump's
/// EMA reserves. A trade that pushes either pool's spot price has already updated the pump with the pre-push
/// reserves (Basin updates pumps before every reserve change) and adds zero seconds to the v3 tick cumulative.
library PriceGuard {
    /// cbETH for `wethIn` at the v3 TWAP. Pool token0 = cbETH, so the tick prices WETH per cbETH.
    function cbEthForWeth(uint256 wethIn) internal view returns (uint256) {
        return FullMath.mulDiv(wethIn, 1 << 128, _wethPerCbX128());
    }

    function wethForCbEth(uint256 cbIn) internal view returns (uint256) {
        return FullMath.mulDiv(cbIn, _wethPerCbX128(), 1 << 128);
    }

    /// Constant product on the pump's EMA reserves, less PI-17's well fee.
    function pintoForCbEth(uint256 cbIn) internal view returns (uint256) {
        (uint256 rPinto, uint256 rCb) = _emaReserves();
        return rPinto * cbIn / (rCb + cbIn) * (1e4 - WELL_FEE_BPS) / 1e4;
    }

    function cbEthForPinto(uint256 pintoIn) internal view returns (uint256) {
        (uint256 rPinto, uint256 rCb) = _emaReserves();
        return rCb * pintoIn / (rPinto + pintoIn) * (1e4 - WELL_FEE_BPS) / 1e4;
    }

    /// Coins for `wethIn` at a coin-pool `tick` (token1 per token0 = 1.0001^tick). Uniswap's
    /// OracleLibrary.getQuoteAtTick, so it holds over the whole tick range.
    function coinsForWeth(uint256 wethIn, int24 tick, bool coinIsToken0) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtP <= type(uint128).max) {
            uint256 rX192 = uint256(sqrtP) * sqrtP;
            return coinIsToken0 ? FullMath.mulDiv(1 << 192, wethIn, rX192) : FullMath.mulDiv(rX192, wethIn, 1 << 192);
        }
        uint256 rX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        return coinIsToken0 ? FullMath.mulDiv(1 << 128, wethIn, rX128) : FullMath.mulDiv(rX128, wethIn, 1 << 128);
    }

    /// WETH per cbETH as a Q128 ratio, from the mean tick over V3_TWAP_SECONDS (rounded toward -inf, as
    /// Uniswap's OracleLibrary does).
    function _wethPerCbX128() private view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = V3_TWAP_SECONDS;
        (int56[] memory cum,) = IUniswapV3Pool(V3_WETH_CBETH_POOL).observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 mean = delta / int56(uint56(V3_TWAP_SECONDS));
        if (delta < 0 && delta % int56(uint56(V3_TWAP_SECONDS)) != 0) mean--;
        int24 tick = int24(mean);
        require(tick == mean, "tick");
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
    }

    /// The pump and its data are read from the well each time, so the guard follows the pump the well actually
    /// updates. The well is an upgradeable proxy and PI-17 is an upgrade: a stored pump the well stopped
    /// updating would fold the well's live (pushable) reserves into its EMA after any idle gap.
    function _emaReserves() private view returns (uint256 rPinto, uint256 rCb) {
        IWell.Call memory pump = IWell(CBETH_WELL).pumps()[0];
        uint256[] memory r = IPump(pump.target).readInstantaneousReserves(CBETH_WELL, pump.data);
        return (r[0], r[1]);
    }
}
