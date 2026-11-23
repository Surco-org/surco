// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TOLL_START_BPS, TOLL_WINDOW, PLATFORM_BPS, TIP_BPS} from "./Constants.sol";

library FeeMath {
    /// Anti-sniper toll: TOLL_START_BPS at launch, linear down to feeBps over TOLL_WINDOW.
    function tollBps(uint256 nowTs, uint256 launchedAt, uint16 feeBps) internal pure returns (uint256) {
        if (launchedAt == 0) return feeBps;
        uint256 elapsed = nowTs <= launchedAt ? 0 : nowTs - launchedAt;
        if (elapsed >= TOLL_WINDOW) return feeBps;
        return TOLL_START_BPS - (TOLL_START_BPS - feeBps) * elapsed / TOLL_WINDOW;
    }

    function split(uint256 weth, uint16 creatorBps)
        internal
        pure
        returns (uint256 platform, uint256 creator, uint256 pinto)
    {
        platform = weth * PLATFORM_BPS / 1e4;
        creator = weth * creatorBps / 1e4;
        pinto = weth - platform - creator;
    }

    function tip(uint256 amount) internal pure returns (uint256) {
        return amount * TIP_BPS / 1e4;
    }
}
