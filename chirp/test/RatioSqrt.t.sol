// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RatioSqrt} from "../src/RatioSqrt.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

contract RatioSqrtTest is Test {
    function test_one_to_one_is_q96() public pure {
        assertEq(RatioSqrt.sqrtPriceX96(1, 1), uint160(1) << 96);
    }

    function test_q192_overflow_is_two_to_128() public pure {
        assertEq(RatioSqrt.sqrtPriceX96(uint256(1) << 64, 1), uint160(1) << 128);
    }

    function test_fixture_floors_inside_one_ulp() public pure {
        uint256 amount1 = 1e12;
        uint256 amount0 = 1e27;
        uint160 p = RatioSqrt.sqrtPriceX96(amount1, amount0);
        uint256 ideal = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        assertLe(uint256(p) * uint256(p), ideal);
        uint256 next = uint256(p) + 1;
        assertGt(next * next, ideal);
    }

    function test_zero_amount1_reverts() public {
        vm.expectRevert(RatioSqrt.BadPrice.selector);
        this.sqrt(0, 1);
    }

    function test_zero_amount0_reverts() public {
        vm.expectRevert(RatioSqrt.BadPrice.selector);
        this.sqrt(1, 0);
    }

    function test_above_max_tick_reverts() public {
        vm.expectRevert(RatioSqrt.BadPrice.selector);
        this.sqrt(type(uint256).max, 1);
    }

    /// @dev External so expectRevert sees a deeper call. The library itself is inlined.
    function sqrt(uint256 amount1, uint256 amount0) external pure returns (uint160) {
        return RatioSqrt.sqrtPriceX96(amount1, amount0);
    }

    /// @dev Exact floor against FullMath wherever amount1/amount0 < 2^64 (so the Q192 ratio fits 256 bits).
    function test_fuzz_floor_is_exact(uint256 amount1, uint256 amount0) public pure {
        amount0 = bound(amount0, 1, type(uint192).max);
        amount1 = bound(amount1, 1, type(uint192).max);
        vm.assume(amount1 / amount0 < (uint256(1) << 64));
        uint256 q = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
        vm.assume(q > (uint256(4295128740) ** 2)); // above MIN_SQRT_PRICE + 1, squared
        uint256 p = RatioSqrt.sqrtPriceX96(amount1, amount0);
        assertLe(p, q / p, "too high");
        assertGt(p + 1, q / (p + 1), "not the floor");
    }

    function test_fuzz_monotone(uint256 a, uint256 b, uint256 amount0) public pure {
        amount0 = bound(amount0, 1e6, 1e30);
        a = bound(a, 1, 1e30);
        b = bound(b, a, 1e30);
        assertLe(RatioSqrt.sqrtPriceX96(a, amount0), RatioSqrt.sqrtPriceX96(b, amount0));
    }
}
