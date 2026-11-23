// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {WETH, POOL_MANAGER, UNIVERSAL_ROUTER, V4_QUOTER, TICK_SPACING, LP_FEE, SUPPLY} from "../../src/Constants.sol";

/// @dev Throwaway. Proves the fee algorithm Task 4 copies into LauncherHook. Flags 0xCC:
///      beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta.
contract ProbeFeeHook {
    IPoolManager public immutable manager;
    address public immutable recipient;
    uint256 public immutable bps;

    constructor(IPoolManager manager_, address recipient_, uint256 bps_) {
        manager = manager_;
        recipient = recipient_;
        bps = bps_;
    }

    /// @dev WETH is the specified currency (exact-in buy, exact-out sell): charge on |amountSpecified|.
    ///      The hook takes the fee (hook delta -fee) and returns +fee as the specified delta, so the
    ///      manager credits it back and the swapper owes it: exact-in swaps fee less, exact-out swaps fee more.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager), "manager");
        if (!_wethSpecified(key, params)) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        int256 s = params.amountSpecified;
        int128 fee = _take(uint256(s < 0 ? -s : s));
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @dev WETH is the unspecified currency (exact-in sell, exact-out buy): charge on the WETH leg of
    ///      the pool's swap delta and return +fee as the unspecified delta, again owed by the swapper.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        require(msg.sender == address(manager), "manager");
        if (_wethSpecified(key, params)) return (this.afterSwap.selector, 0);
        int128 leg = Currency.unwrap(key.currency0) == WETH ? delta.amount0() : delta.amount1();
        return (this.afterSwap.selector, _take(uint256(int256(leg < 0 ? -leg : leg))));
    }

    /// @dev Dust rounds to 0: skip take, return 0.
    function _take(uint256 wethLeg) internal returns (int128 fee) {
        uint256 amount = wethLeg * bps / 10_000;
        if (amount == 0) return 0;
        manager.take(Currency.wrap(WETH), recipient, amount);
        return int128(int256(amount)); // ponytail: probe only; the real hook uses SafeCast
    }

    /// @dev Same rule as Hooks.afterSwap: exact-in zeroForOne and exact-out oneForZero specify currency0.
    function _wethSpecified(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        pure
        returns (bool)
    {
        Currency specified = (params.amountSpecified < 0) == params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(specified) == WETH;
    }
}

contract Coin is ERC20("Coin", "COIN", 18) {
    constructor() {
        _mint(msg.sender, SUPPLY);
    }
}

/// @dev Adds liquidity inside an unlock and pays for it.
contract LiquidityProbe is IUnlockCallback {
    IPoolManager internal constant MANAGER = IPoolManager(POOL_MANAGER);

    function add(PoolKey calldata key, uint256 liquidity) external {
        MANAGER.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "manager");
        (PoolKey memory key, uint256 liquidity) = abi.decode(data, (PoolKey, uint256));
        (BalanceDelta delta,) = MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }

    function _pay(Currency currency, int128 amount) internal {
        MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(MANAGER), uint128(-amount));
        MANAGER.settle();
    }
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

// Uniswap's Permit2 on Base (not checked; only the tests' Universal Router trades use it).
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Mirrors IV4Quoter at 0x0d5e…048D (Sourcify source, checked 2026-11-20).
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
}

/// @dev The gate. Every case runs with the coin on both sides of WETH (two concrete contracts below).
abstract contract RouterGateBase is Test {
    // Universal Router Commands.sol and v4-periphery Actions.sol, from the UR's Sourcify source (2026-11-20).
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    // v4-periphery IV4Router structs, same source.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    /// Base, 2026-11-20: the block every fork test pins (Task 11).
    uint256 internal constant FORK_BLOCK = 60_050_000;
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant LIQUIDITY = 1_000e18; // ~1,000 of each token at price 1
    address internal constant FEE_TO = address(0xFEE);
    address internal constant TRADER = address(0x7AADE);
    address internal constant HOOK = 0xfEE00000000000000000000000000000000000CC;

    IV4Quoter internal constant QUOTER = IV4Quoter(V4_QUOTER);
    IUniversalRouter internal constant ROUTER = IUniversalRouter(UNIVERSAL_ROUTER);

    Coin internal coin;
    PoolKey internal key;

    function _coinAddress() internal pure virtual returns (address);

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        deployCodeTo("RouterGate.t.sol:ProbeFeeHook", abi.encode(POOL_MANAGER, FEE_TO, FEE_BPS), HOOK);
        deployCodeTo("RouterGate.t.sol:Coin", _coinAddress());
        coin = Coin(_coinAddress());

        (address c0, address c1) = address(coin) < WETH ? (address(coin), WETH) : (WETH, address(coin));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, TICK_SPACING, IHooks(HOOK));
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));

        LiquidityProbe lp = new LiquidityProbe();
        coin.transfer(address(lp), 10_000e18);
        deal(WETH, address(lp), 10_000e18);
        lp.add(key, LIQUIDITY);

        coin.transfer(TRADER, 100e18);
        deal(WETH, TRADER, 100e18);
        vm.startPrank(TRADER);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        coin.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(address(coin), UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ---- the gate ----

    function test_ur_exact_in_buy_fee_in_weth() public {
        (int256 dWeth, int256 dCoin, uint256 fee) = _exactIn(true, 1 ether);
        assertEq(fee, 0.01 ether, "fee is 1% of the WETH in");
        assertEq(dWeth, -1 ether, "trader pays exactly 1 WETH");
        assertGt(dCoin, 0, "trader gets coins");
    }

    function test_ur_exact_in_sell_fee_in_weth() public {
        (int256 dWeth, int256 dCoin, uint256 fee) = _exactIn(false, 1 ether);
        uint256 paidOut = uint256(dWeth) + fee; // all the WETH the pool released; the trader keeps the rest
        assertGt(fee, 0, "fee taken");
        assertEq(fee, paidOut * FEE_BPS / 10_000, "fee is 1% of the pool's WETH out, trader gets 99%");
        assertEq(dCoin, -1 ether, "trader pays exactly the coins in");
    }

    function test_ur_exact_out_buy() public {
        (int256 dWeth, int256 dCoin, uint256 fee) = _exactOut(true, 1 ether);
        uint256 poolIn = uint256(-dWeth) - fee; // the WETH the pool kept
        assertGt(fee, 0, "fee taken");
        assertEq(fee, poolIn * FEE_BPS / 10_000, "fee is 1% of the pool's WETH in");
        assertEq(dCoin, 1 ether, "trader gets exactly the coins asked for");
    }

    function test_ur_exact_out_sell() public {
        (int256 dWeth, int256 dCoin, uint256 fee) = _exactOut(false, 0.5 ether);
        assertEq(fee, 0.005 ether, "fee is 1% of the WETH out");
        assertEq(dWeth, 0.5 ether, "trader gets exactly the WETH asked for");
        assertLt(dCoin, 0, "trader pays coins");
    }

    function test_quoter_matches_swap() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; i++) {
            bool buy = i == 0;
            (uint256 quotedOut,) = QUOTER.quoteExactInputSingle(_quote(buy, 1 ether));
            (int256 dWeth, int256 dCoin,) = _exactIn(buy, 1 ether);
            assertEq(quotedOut, uint256(buy ? dCoin : dWeth), "exact-in quote == delivered");
            vm.revertToState(snap);

            (uint256 quotedIn,) = QUOTER.quoteExactOutputSingle(_quote(buy, 0.5 ether));
            (dWeth, dCoin,) = _exactOut(buy, 0.5 ether);
            assertEq(quotedIn, uint256(-(buy ? dWeth : dCoin)), "exact-out quote == paid");
            vm.revertToState(snap);
        }
    }

    function test_dust_trade_ok() public {
        for (uint256 i; i < 2; i++) {
            bool buy = i == 0;
            (,, uint256 fee) = _exactIn(buy, 1);
            assertEq(fee, 0, "exact-in dust: no fee");
            (,, fee) = _exactOut(buy, 1);
            assertEq(fee, 0, "exact-out dust: no fee");
        }
    }

    // ---- Universal Router plumbing ----

    function _exactIn(bool buy, uint128 amountIn) internal returns (int256 dWeth, int256 dCoin, uint256 fee) {
        bool zeroForOne = _zeroForOne(buy);
        bytes memory swap = abi.encode(
            ExactInputSingleParams({
                poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: 0, hookData: ""
            })
        );
        return _execute(SWAP_EXACT_IN_SINGLE, swap, buy, amountIn, 0);
    }

    function _exactOut(bool buy, uint128 amountOut) internal returns (int256 dWeth, int256 dCoin, uint256 fee) {
        bool zeroForOne = _zeroForOne(buy);
        bytes memory swap = abi.encode(
            ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: type(uint128).max,
                hookData: ""
            })
        );
        return _execute(SWAP_EXACT_OUT_SINGLE, swap, buy, type(uint128).max, amountOut);
    }

    function _execute(uint8 action, bytes memory swap, bool buy, uint256 maxIn, uint256 minOut)
        internal
        returns (int256 dWeth, int256 dCoin, uint256 fee)
    {
        (address tokenIn, address tokenOut) = buy ? (WETH, address(coin)) : (address(coin), WETH);
        bytes[] memory params = new bytes[](3);
        params[0] = swap;
        params[1] = abi.encode(tokenIn, maxIn);
        params[2] = abi.encode(tokenOut, minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(action, SETTLE_ALL, TAKE_ALL), params);

        uint256 weth0 = IERC20(WETH).balanceOf(TRADER);
        uint256 coin0 = coin.balanceOf(TRADER);
        uint256 fee0 = IERC20(WETH).balanceOf(FEE_TO);
        vm.prank(TRADER);
        ROUTER.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
        dWeth = int256(IERC20(WETH).balanceOf(TRADER)) - int256(weth0);
        dCoin = int256(coin.balanceOf(TRADER)) - int256(coin0);
        fee = IERC20(WETH).balanceOf(FEE_TO) - fee0;
    }

    function _quote(bool buy, uint128 amount) internal view returns (IV4Quoter.QuoteExactSingleParams memory) {
        return IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: _zeroForOne(buy), exactAmount: amount, hookData: ""
        });
    }

    /// @dev A buy sends WETH in.
    function _zeroForOne(bool buy) internal view returns (bool) {
        return buy == (Currency.unwrap(key.currency0) == WETH);
    }
}

contract RouterGateCoinToken0Test is RouterGateBase {
    function _coinAddress() internal pure override returns (address) {
        return 0x1111111111111111111111111111111111111111;
    }
}

contract RouterGateCoinToken1Test is RouterGateBase {
    function _coinAddress() internal pure override returns (address) {
        return 0xC0C0c0c0C0C0c0c0c0C0c0C0C0C0C0C0C0C0c0c0;
    }
}
