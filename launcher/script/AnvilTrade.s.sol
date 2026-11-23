// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IUniversalRouter, IPermit2, PERMIT2, RouterGateBase} from "../test/fork/RouterGate.t.sol";
import {WETH, UNIVERSAL_ROUTER, LP_FEE, TICK_SPACING} from "../src/Constants.sol";

interface IWETH9 {
    function deposit() external payable;
}

/// @notice Anvil fork or Base mainnet (used on mainnet 2026-11-21 with SIZE_WEI=5e14). Round trips through the Universal Router so a coin's vault collects fees:
///   COIN=0x… HOOK=0x… ROUNDS=5 SIZE_WEI=1e18 forge script script/AnvilTrade.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <impersonated trader>
contract AnvilTrade is Script {
    function run() external {
        require(block.chainid == 8453 && block.number > 0, "fork of Base");
        address coin = vm.envAddress("COIN");
        address hook = vm.envAddress("HOOK");
        uint256 rounds = vm.envOr("ROUNDS", uint256(5));
        uint128 size = uint128(vm.envOr("SIZE_WEI", uint256(1 ether)));
        (address a, address b) = coin < WETH ? (coin, WETH) : (WETH, coin);
        PoolKey memory key = PoolKey(Currency.wrap(a), Currency.wrap(b), LP_FEE, TICK_SPACING, IHooks(hook));

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        IWETH9(WETH).deposit{value: size * rounds}();
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IERC20(coin).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(coin, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        for (uint256 i; i < rounds; i++) {
            uint256 c0 = IERC20(coin).balanceOf(me);
            _swap(key, coin, true, size);
            _swap(key, coin, false, uint128(IERC20(coin).balanceOf(me) - c0));
        }
        vm.stopBroadcast();
        console.log("trader WETH after", IERC20(WETH).balanceOf(me));
    }

    function _swap(PoolKey memory key, address coin, bool buy, uint128 amountIn) internal {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == WETH);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(RouterGateBase.ExactInputSingleParams(key, zeroForOne, amountIn, 0, ""));
        params[1] = abi.encode(buy ? WETH : coin, uint256(amountIn));
        params[2] = abi.encode(buy ? coin : WETH, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params); // EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 1 hours);
    }
}
