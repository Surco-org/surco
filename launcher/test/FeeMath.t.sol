// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {FeeMath} from "../src/FeeMath.sol";
import {TOLL_START_BPS, TOLL_WINDOW, MAX_CREATOR_BPS, MIN_FEE_BPS, MAX_FEE_BPS} from "../src/Constants.sol";

contract FeeMathTest is Test {
    uint256 constant T0 = 1_000_000;

    function test_toll_endpoints() public pure {
        assertEq(FeeMath.tollBps(T0, T0, 100), TOLL_START_BPS);
        assertEq(FeeMath.tollBps(T0 + TOLL_WINDOW, T0, 100), 100);
        assertEq(FeeMath.tollBps(T0 + TOLL_WINDOW + 1 days, T0, 100), 100);
        assertApproxEqAbs(FeeMath.tollBps(T0 + 300, T0, 100), (TOLL_START_BPS + 100) / 2, 1);
        assertEq(FeeMath.tollBps(T0, 0, 100), 100); // clock not started
    }

    function testFuzz_toll_monotonic(uint256 a, uint256 b, uint16 fee) public pure {
        fee = uint16(bound(fee, MIN_FEE_BPS, MAX_FEE_BPS));
        a = bound(a, 0, 2 * TOLL_WINDOW);
        b = bound(b, a, 2 * TOLL_WINDOW);
        assertGe(FeeMath.tollBps(T0 + a, T0, fee), FeeMath.tollBps(T0 + b, T0, fee));
        assertGe(FeeMath.tollBps(T0 + a, T0, fee), fee);
    }

    function testFuzz_split_sums_exactly(uint256 weth, uint16 creatorBps) public pure {
        weth = bound(weth, 0, type(uint128).max);
        creatorBps = uint16(bound(creatorBps, 0, MAX_CREATOR_BPS));
        (uint256 p, uint256 c, uint256 pinto) = FeeMath.split(weth, creatorBps);
        assertEq(p + c + pinto, weth);
    }

    function test_split_spec_example() public pure {
        (uint256 p, uint256 c, uint256 pinto) = FeeMath.split(1e18, 2000);
        assertEq(p, 0.2e18);
        assertEq(c, 0.2e18);
        assertEq(pinto, 0.6e18);
        assertEq(FeeMath.tip(pinto), 0.003e18); // TIP_BPS=50 of the 0.6 batch
    }
}
