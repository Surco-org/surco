// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IWell} from "../../src/interfaces/IWell.sol";
import {IPump} from "../../src/interfaces/IPump.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {PintoRoute} from "../../src/PintoRoute.sol";
import {
    WETH,
    CBETH,
    PINTO,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    SWAP_ROUTER02,
    V3_POOL_FEE,
    WELL_TOL_BPS,
    V3_TOL_BPS,
    WELL_FEE_BPS,
    MAX_CONVERT_WETH,
    MAX_BUYBACK_PINTO
} from "../../src/Constants.sol";

/// Exposes the internal libraries so the route runs in this contract's context, as it will in a vault's.
contract RouteHarness {
    function wethToPinto(uint256 wethIn) external returns (uint256) {
        return PintoRoute.wethToPinto(wethIn);
    }

    function pintoToWeth(uint256 pintoIn) external returns (uint256) {
        return PintoRoute.pintoToWeth(pintoIn);
    }

    function cbEthForWeth(uint256 wethIn) external view returns (uint256) {
        return PriceGuard.cbEthForWeth(wethIn);
    }

    function wethForCbEth(uint256 cbIn) external view returns (uint256) {
        return PriceGuard.wethForCbEth(cbIn);
    }

    function pintoForCbEth(uint256 cbIn) external view returns (uint256) {
        return PriceGuard.pintoForCbEth(cbIn);
    }

    function cbEthForPinto(uint256 pintoIn) external view returns (uint256) {
        return PriceGuard.cbEthForPinto(pintoIn);
    }
}

contract PintoRouteForkTest is Test {
    /// Pinned so results reproduce: Base block 60,050,000 (2026-11-20). At this block the well charged no swap
    /// fee yet (PI-17 not executed): getSwapOut equals the fee-less constant product of getReserves.
    uint256 constant FORK_BLOCK = 60_050_000;

    RouteHarness h;
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        h = new RouteHarness();
    }

    function _fundWeth(address to, uint256 amount) internal {
        vm.deal(to, amount);
        vm.prank(to);
        IWETH(WETH).deposit{value: amount}();
    }

    /// Within `tolBps` of `quote`, either side. Logs the deviation (visible with -vv).
    function _assertNear(uint256 actual, uint256 quote, uint256 tolBps) internal {
        emit log_named_int("actual vs guard, bps x100", (int256(actual) - int256(quote)) * 1e6 / int256(quote));
        assertGe(actual, quote * (1e4 - tolBps) / 1e4, "below tolerance");
        assertLe(actual, quote * (1e4 + tolBps) / 1e4, "above tolerance");
    }

    function test_weth_to_pinto_real() public {
        uint256 wethIn = MAX_CONVERT_WETH;
        _fundWeth(address(h), wethIn);
        uint256 quote = h.pintoForCbEth(h.cbEthForWeth(wethIn));

        uint256 out = h.wethToPinto(wethIn);

        assertGt(out, 0);
        assertEq(IERC20(PINTO).balanceOf(address(h)), out);
        _assertNear(out, quote, WELL_TOL_BPS + V3_TOL_BPS);
        assertEq(IERC20(WETH).balanceOf(address(h)), 0, "weth left");
        assertEq(IERC20(CBETH).balanceOf(address(h)), 0, "cbeth left");
        assertEq(_allowance(WETH, SWAP_ROUTER02), 0);
        assertEq(_allowance(CBETH, CBETH_WELL), 0);
    }

    function test_pinto_to_weth_real() public {
        uint256 pintoIn = MAX_BUYBACK_PINTO;
        deal(PINTO, address(h), pintoIn);
        uint256 quote = h.wethForCbEth(h.cbEthForPinto(pintoIn));

        uint256 out = h.pintoToWeth(pintoIn);

        assertGt(out, 0);
        assertEq(IERC20(WETH).balanceOf(address(h)), out);
        _assertNear(out, quote, WELL_TOL_BPS + V3_TOL_BPS);
        assertEq(IERC20(PINTO).balanceOf(address(h)), 0, "pinto left");
        assertEq(IERC20(CBETH).balanceOf(address(h)), 0, "cbeth left");
        assertEq(_allowance(PINTO, CBETH_WELL), 0);
        assertEq(_allowance(CBETH, SWAP_ROUTER02), 0);
    }

    /// Review Focus 5: someone buys Pinto out of the well in the same transaction, so our cbETH buys well past
    /// WELL_TOL_BPS less Pinto than the pump EMA says. The pump was updated with the pre-push reserves, so the guard
    /// does not move.
    function test_spot_pushed_reverts() public {
        _fundWeth(address(h), MAX_CONVERT_WETH);
        uint256 quoteBefore = h.pintoForCbEth(1 ether);
        uint256 spotBefore = IWell(CBETH_WELL).getSwapOut(CBETH, PINTO, 1 ether);

        uint256 push = 0.5 ether;
        deal(CBETH, attacker, push);
        vm.startPrank(attacker);
        IERC20(CBETH).approve(CBETH_WELL, push);
        IWell(CBETH_WELL).swapFrom(CBETH, PINTO, push, 0, attacker, block.timestamp);
        vm.stopPrank();

        uint256 spotAfter = IWell(CBETH_WELL).getSwapOut(CBETH, PINTO, 1 ether);
        assertLt(spotAfter, spotBefore * (1e4 - WELL_TOL_BPS) / 1e4, "spot moved past WELL_TOL_BPS");
        assertEq(h.pintoForCbEth(1 ether), quoteBefore, "guard ignores same-block push");

        vm.expectPartialRevert(SlippageOut.selector, CBETH_WELL);
        h.wethToPinto(MAX_CONVERT_WETH);
    }

    /// The other pool: someone dumps WETH into the v3 pool in the same transaction. The 30-minute TWAP does not
    /// move, so the router's amountOutMinimum refuses the fill.
    function test_v3_spot_pushed_reverts() public {
        _fundWeth(address(h), MAX_CONVERT_WETH);
        uint256 quoteBefore = h.cbEthForWeth(1 ether);

        uint256 push = 2_000 ether;
        _fundWeth(attacker, push);
        vm.startPrank(attacker);
        IERC20(WETH).approve(SWAP_ROUTER02, push);
        uint256 cbOut = ISwapRouter02(SWAP_ROUTER02)
            .exactInputSingle(ISwapRouter02.ExactInputSingleParams(WETH, CBETH, V3_POOL_FEE, attacker, push, 0, 0));
        vm.stopPrank();

        assertLt(cbOut, quoteBefore * push / 1 ether * (1e4 - V3_TOL_BPS) / 1e4, "spot moved past V3_TOL_BPS");
        assertEq(h.cbEthForWeth(1 ether), quoteBefore, "TWAP ignores same-block push");

        vm.expectRevert(bytes("Too little received"));
        h.wethToPinto(MAX_CONVERT_WETH);
    }

    /// The guard deducts PI-17's 25 bps from the pump's constant-product quote, and still lands within
    /// WELL_TOL_BPS of what the well pays. At FORK_BLOCK the well itself charges no fee, so the actual out is
    /// ~25 bps above the guard.
    function test_well_fee_accounted() public {
        uint256 cbIn = 0.01 ether;
        (uint256 rPinto, uint256 rCb) = _pumpReserves();
        uint256 feeless = rPinto * cbIn / (rCb + cbIn);
        uint256 guard = h.pintoForCbEth(cbIn);
        assertEq(guard, feeless * (1e4 - WELL_FEE_BPS) / 1e4, "guard = CP on EMA less 25 bps");

        uint256[] memory r = IWell(CBETH_WELL).getReserves();
        uint256 spot = IWell(CBETH_WELL).getSwapOut(CBETH, PINTO, cbIn);
        assertApproxEqAbs(spot, r[0] * cbIn / (r[1] + cbIn), 1, "no well fee live at FORK_BLOCK");

        deal(CBETH, address(this), cbIn);
        IERC20(CBETH).approve(CBETH_WELL, cbIn);
        uint256 actual = IWell(CBETH_WELL).swapFrom(CBETH, PINTO, cbIn, 0, address(this), block.timestamp);
        _assertNear(actual, guard, WELL_TOL_BPS);
        assertGt(actual, guard, "fee-less well pays above the fee-deducted guard");
    }

    function _pumpReserves() internal view returns (uint256, uint256) {
        IWell.Call memory pump = IWell(CBETH_WELL).pumps()[0];
        assertEq(pump.target, CBETH_WELL_PUMP);
        uint256[] memory r = IPump(pump.target).readInstantaneousReserves(CBETH_WELL, pump.data);
        return (r[0], r[1]);
    }

    function _allowance(address token, address spender) internal view returns (uint256) {
        (, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", address(h), spender));
        return abi.decode(ret, (uint256));
    }
}

/// Basin's Well error for a swap below minAmountOut.
error SlippageOut(uint256 amountOut, uint256 minAmountOut);
