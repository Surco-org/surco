// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IWell} from "./interfaces/IWell.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {PriceGuard} from "./PriceGuard.sol";
import {WETH, CBETH, PINTO, CBETH_WELL, SWAP_ROUTER02, V3_POOL_FEE, V3_TOL_BPS, WELL_TOL_BPS} from "./Constants.sol";

/// WETH <-> cbETH (Uniswap v3, 0.01%) <-> Pinto (Basin cbETH well). Internal, so it runs in the calling vault's
/// context and leaves the output with it. Each leg's minimum out is its PriceGuard quote less that leg's tolerance
/// (V3_TOL_BPS, WELL_TOL_BPS), so a spot price pushed in the same transaction reverts the route instead of overpaying.
library PintoRoute {
    function wethToPinto(uint256 wethIn) internal returns (uint256 pintoOut) {
        uint256 cbOut = _v3(WETH, CBETH, wethIn, PriceGuard.cbEthForWeth(wethIn));
        pintoOut = _well(CBETH, PINTO, cbOut, PriceGuard.pintoForCbEth(cbOut));
    }

    function pintoToWeth(uint256 pintoIn) internal returns (uint256 wethOut) {
        uint256 cbOut = _well(PINTO, CBETH, pintoIn, PriceGuard.cbEthForPinto(pintoIn));
        wethOut = _v3(CBETH, WETH, cbOut, PriceGuard.wethForCbEth(cbOut));
    }

    function _v3(address tokenIn, address tokenOut, uint256 amountIn, uint256 quote) private returns (uint256 out) {
        IERC20(tokenIn).approve(SWAP_ROUTER02, amountIn);
        out = ISwapRouter02(SWAP_ROUTER02)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: V3_POOL_FEE,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: quote * (1e4 - V3_TOL_BPS) / 1e4,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(tokenIn).approve(SWAP_ROUTER02, 0);
    }

    function _well(address fromToken, address toToken, uint256 amountIn, uint256 quote) private returns (uint256 out) {
        IERC20(fromToken).approve(CBETH_WELL, amountIn);
        out = IWell(CBETH_WELL)
            .swapFrom(fromToken, toToken, amountIn, quote * (1e4 - WELL_TOL_BPS) / 1e4, address(this), block.timestamp);
        IERC20(fromToken).approve(CBETH_WELL, 0);
    }
}
