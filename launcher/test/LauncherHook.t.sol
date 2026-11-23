// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {WETH, TICK_SPACING, LP_FEE, EMA_WINDOW, MIN_FEE_BPS, MAX_FEE_BPS} from "../src/Constants.sol";

/// @dev Stands in for any router, and for the factory and the vault. Each call runs inside an unlock;
///      whoever calls it pays its debts (transferFrom) and receives its credits.
contract Actor is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external {
        manager.unlock(abi.encode(msg.sender, key, uint8(0), zeroForOne, amountSpecified));
    }

    function modify(PoolKey calldata key, int256 liquidity) external {
        manager.unlock(abi.encode(msg.sender, key, uint8(1), false, liquidity));
    }

    function donate(PoolKey calldata key) external {
        manager.unlock(abi.encode(msg.sender, key, uint8(2), false, int256(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (address payer, PoolKey memory key, uint8 op, bool zeroForOne, int256 amount) =
            abi.decode(data, (address, PoolKey, uint8, bool, int256));
        BalanceDelta d;
        if (op == 0) {
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            d = manager.swap(key, IPoolManager.SwapParams(zeroForOne, amount, limit), "");
        } else if (op == 1) {
            int24 lo = TickMath.minUsableTick(key.tickSpacing);
            int24 hi = TickMath.maxUsableTick(key.tickSpacing);
            (d,) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lo, hi, amount, 0), "");
        } else {
            d = manager.donate(key, 1, 1, "");
        }
        _settle(key.currency0, d.amount0(), payer);
        _settle(key.currency1, d.amount1(), payer);
        return "";
    }

    function _settle(Currency currency, int128 amount, address payer) internal {
        if (amount < 0) {
            manager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint128(-amount));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint128(amount));
        }
    }
}

/// @dev Every test runs with the coin on both sides of WETH (the two concrete contracts at the bottom).
abstract contract LauncherHookBase is Test {
    using StateLibrary for IPoolManager;

    // Exactly the eight required flags (0x2AEC) in the low 14 bits.
    address internal constant HOOK = address(uint160(0x2AEC | (uint256(0xB0B) << 148)));
    address internal constant TRADER = address(0x7AADE);
    uint16 internal constant FEE_BPS = 100;
    int24 internal constant START_TICK = 1000;

    IPoolManager internal manager;
    LauncherHook internal hook;
    MockERC20 internal weth;
    MockERC20 internal coin;
    Actor internal factory;
    Actor internal router;
    Actor internal vault;
    PoolKey internal key;
    PoolId internal id;

    function _coinAddress() internal pure virtual returns (address);

    function setUp() public {
        manager = new PoolManager(address(this));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Wrapped Ether", "WETH", uint8(18)), WETH);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Coin", "COIN", uint8(18)), _coinAddress());
        weth = MockERC20(WETH);
        coin = MockERC20(_coinAddress());

        factory = new Actor(manager);
        router = new Actor(manager);
        vault = new Actor(manager);
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(factory), WETH), HOOK);
        hook = LauncherHook(HOOK);

        key = _key(address(coin), TICK_SPACING);
        id = key.toId();
        vm.startPrank(address(factory));
        hook.register(key, address(vault), FEE_BPS);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));
        vm.stopPrank();

        weth.mint(address(this), 10_000e18);
        coin.mint(address(this), 10_000e18);
        weth.approve(address(factory), type(uint256).max);
        coin.approve(address(factory), type(uint256).max);
        factory.modify(key, 1_000e18);

        // R9: the beforeSwap take is paid from the manager's float before the trader settles.
        weth.mint(address(manager), 1_000e18);

        weth.mint(TRADER, 1_000e18);
        coin.mint(TRADER, 1_000e18);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        coin.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ---- swaps and the fee ----

    function test_any_router_can_swap() public {
        uint256 coins0 = coin.balanceOf(TRADER);
        _swap(router, true, true, 1e18);
        assertGt(coin.balanceOf(TRADER), coins0, "plain unlock helper bought coins");
        (uint256 got,) = _swap(router, false, true, 1e18);
        assertGt(got, 0, "and sold them");
    }

    function test_exact_in_buy_fee_to_vault() public {
        _case(true, true, 1e18, FEE_BPS);
    }

    function test_exact_out_buy_fee_to_vault() public {
        _case(true, false, 1e18, FEE_BPS);
    }

    function test_exact_in_sell_fee_to_vault() public {
        _case(false, true, 1e18, FEE_BPS);
    }

    function test_exact_out_sell_fee_to_vault() public {
        _case(false, false, 0.5e18, FEE_BPS);
    }

    function test_toll_charged_in_window() public {
        vm.prank(address(factory));
        hook.startClock(id);
        uint256 t0 = block.timestamp;
        assertEq(hook.coin(id).launchedAt, t0, "clock started");

        _allCases(8000); // at launch: TOLL_START_BPS
        vm.warp(t0 + 300);
        _allCases(4050); // halfway: (8000 + 100) / 2
        vm.warp(t0 + 600);
        _allCases(FEE_BPS); // window over
    }

    function test_vault_swap_exempt() public {
        assertEq(hook.coin(id).emaTs, 0, "unseeded");
        for (uint256 i; i < 4; i++) {
            (bool buy, bool exactIn) = (i < 2, i % 2 == 0);
            uint256 amount = (buy || exactIn) ? 1e18 : 0.5e18;
            (uint256 leg, uint256 fee) = _swap(vault, buy, exactIn, amount);
            assertEq(fee, 0, "no fee when the vault swaps");
            if (buy == exactIn) assertEq(leg, amount, "exact WETH leg");
        }
        assertEq(hook.coin(id).emaTs, block.timestamp, "a vault swap still updates the EMA");
        assertEq(hook.emaTick(id), START_TICK, "seeded by the vault's swap");
    }

    function test_dust_trade_ok() public {
        _expectNoFeeTake();
        for (uint256 i; i < 4; i++) {
            (, uint256 fee) = _swap(router, i < 2, i % 2 == 0, 1);
            assertEq(fee, 0, "1-wei trade: no fee");
        }
    }

    /// @dev At 100 bps a 99-wei WETH leg rounds the fee to 0: the swap succeeds and the hook skips take.
    ///      Exact-in buy and exact-out sell, where WETH is the specified leg.
    function test_dust_boundary_99_wei_no_take() public {
        _expectNoFeeTake();
        for (uint256 i; i < 2; i++) {
            (uint256 leg, uint256 fee) = _swap(router, i == 0, i == 0, 99);
            assertEq(leg, 99, "99-wei leg");
            assertEq(fee, 0, "fee rounds to 0");
        }
    }

    /// @dev ...and a 100-wei leg pays 1.
    function test_dust_boundary_100_wei_fee_1() public {
        for (uint256 i; i < 2; i++) {
            (uint256 leg, uint256 fee) = _swap(router, i == 0, i == 0, 100);
            assertEq(leg, 100, "100-wei leg");
            assertEq(fee, 1, "fee 1");
        }
    }

    // ---- liquidity, donate, init ----

    function test_remove_liquidity_reverts() public {
        vm.expectRevert(_wrapped(IHooks.beforeRemoveLiquidity.selector, LauncherHook.LiquidityLocked.selector));
        factory.modify(key, -1e18);
    }

    function test_add_liquidity_non_factory_reverts() public {
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, LauncherHook.OnlyFactory.selector));
        router.modify(key, 1e18);
    }

    function test_donate_reverts() public {
        vm.expectRevert(_wrapped(IHooks.beforeDonate.selector, LauncherHook.NoDonate.selector));
        router.donate(key);
    }

    function test_unregistered_pool_init_reverts() public {
        PoolKey memory other = _key(address(coin), 60);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, LauncherHook.NotRegistered.selector));
        vm.prank(address(factory));
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));

        // Registered, but someone other than the factory initialises it.
        vm.prank(address(factory));
        hook.register(other, address(vault), FEE_BPS);
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, LauncherHook.OnlyFactory.selector));
        vm.prank(TRADER);
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));
    }

    function test_register() public {
        LauncherHook.Coin memory c = hook.coin(id);
        assertEq(c.vault, address(vault));
        assertEq(c.feeBps, FEE_BPS);
        assertEq(c.launchedAt, 0);
        assertEq(c.coinIsToken0, address(coin) < WETH, "coin side");
        assertEq(hook.factory(), address(factory));

        PoolKey memory other = _key(address(coin), 60);
        vm.startPrank(TRADER);
        vm.expectRevert(LauncherHook.OnlyFactory.selector);
        hook.register(other, TRADER, FEE_BPS);
        vm.expectRevert(LauncherHook.OnlyFactory.selector);
        hook.startClock(id);
        vm.stopPrank();

        vm.startPrank(address(factory));
        vm.expectRevert(LauncherHook.AlreadyRegistered.selector);
        hook.register(key, TRADER, FEE_BPS);
        PoolKey memory noWeth = key;
        (noWeth.currency0, noWeth.currency1) = (Currency.wrap(address(1)), Currency.wrap(address(2)));
        vm.expectRevert(LauncherHook.NotWethPool.selector);
        hook.register(noWeth, address(vault), FEE_BPS);
        vm.stopPrank();
    }

    function test_register_fee_out_of_range_reverts() public {
        PoolKey memory other = _key(address(coin), 60);
        vm.startPrank(address(factory));
        vm.expectRevert(LauncherHook.BadFee.selector);
        hook.register(other, address(vault), uint16(MIN_FEE_BPS - 1));
        vm.expectRevert(LauncherHook.BadFee.selector);
        hook.register(other, address(vault), uint16(MAX_FEE_BPS + 1));
        hook.register(other, address(vault), uint16(MIN_FEE_BPS)); // both ends are allowed
        hook.register(_key(address(coin), 10), address(vault), uint16(MAX_FEE_BPS));
        vm.stopPrank();
    }

    function test_start_clock_twice_reverts() public {
        vm.startPrank(address(factory));
        hook.startClock(id);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(LauncherHook.ClockStarted.selector);
        hook.startClock(id);
        vm.stopPrank();
    }

    function test_bad_hook_address_reverts() public {
        vm.expectRevert(LauncherHook.BadHookAddress.selector);
        new LauncherHook(manager, address(factory), WETH);
    }

    // ---- EMA ----

    function test_ema_moves_once_per_block() public {
        assertEq(hook.coin(id).emaTs, 0, "unseeded");
        _swap(router, true, true, 300e18);
        assertEq(hook.emaTick(id), START_TICK, "first swap seeds with the pre-swap tick");
        assertEq(hook.coin(id).emaTs, block.timestamp);
        int24 a = _tick();

        vm.warp(block.timestamp + 2);
        _swap(router, true, true, 1e18);
        int24 e1 = hook.emaTick(id);
        int256 w = int256(EMA_WINDOW);
        assertEq(e1, int24((START_TICK * w + (int256(a) - START_TICK) * 2) / w), "2s of the window");
        assertTrue(e1 != START_TICK, "it moved");

        _swap(router, false, true, 200e18); // same block, price moved again
        assertEq(hook.emaTick(id), e1, "second swap in the block does not move it");
    }

    function test_ema_resists_one_block_spike() public {
        _swap(router, true, true, 1e15); // seed
        vm.warp(block.timestamp + 2);
        _swap(router, true, true, 500e18); // the spike
        int24 e0 = hook.emaTick(id);
        assertApproxEqAbs(e0, START_TICK, 1, "spike block: the EMA saw only the pre-spike tick");
        int256 jump = int256(_tick()) - e0;
        assertGt(jump < 0 ? -jump : jump, 3000, "a real spike");

        vm.warp(block.timestamp + 2);
        _swap(router, true, true, 1);
        int256 moved = int256(hook.emaTick(id)) - e0;
        assertTrue(moved != 0, "it moved");
        assertLe(moved < 0 ? -moved : moved, (jump < 0 ? -jump : jump) * 2 / int256(EMA_WINDOW) + 1, "<= 2s/window");
    }

    /// @dev Spot held ~500 ticks off the EMA, a 1-wei swap every block for one window: the EMA covers
    ///      1 - (1 - 2/1800)^900 ~= 1 - 1/e of the gap. With a whole-tick EMA it covered 0 (dead zone).
    function test_ema_tracks_slow_drift() public {
        _swap(router, true, true, 1e15); // seed at START_TICK
        _swap(router, true, true, 26e18); // same block: spot moves, the EMA does not
        int256 e0 = hook.emaTick(id);
        int256 gap = int256(_tick()) - e0;
        int256 absGap = gap < 0 ? -gap : gap;
        assertGt(absGap, 300, "gap beyond MAX_TICK_DRIFT");
        assertLt(absGap, 900, "inside the old dead zone");

        for (uint256 i; i < 900; i++) {
            vm.warp(block.timestamp + 2);
            _swap(router, true, true, 1);
        }
        int256 covered = (int256(hook.emaTick(id)) - e0) * 1e4 / gap; // bps of the gap
        assertApproxEqAbs(covered, 6321, 100, "~1 - 1/e of the gap");
    }

    function test_ema_clamps_at_window() public {
        _swap(router, true, true, 1e15); // seed
        _swap(router, true, true, 26e18); // same block: spot moves away
        int24 spot = _tick();
        vm.warp(block.timestamp + EMA_WINDOW + 100);
        _swap(router, true, true, 1);
        assertEq(hook.emaTick(id), spot, "dt >= window: the EMA jumps to the tick");
    }

    // ---- helpers ----

    /// @dev Asserts the fee is `bps` of the trader's WETH leg (R8) and the exact per-case formula.
    function _case(bool buy, bool exactIn, uint256 amount, uint256 bps) internal {
        (uint256 leg, uint256 fee) = _swap(router, buy, exactIn, amount);
        assertGt(fee, 0, "fee landed in the vault");
        assertApproxEqAbs(fee, leg * bps / 1e4, 1, "fee = bps of the trader's WETH leg");
        if (buy == exactIn) {
            // WETH specified: exact-in buy pays exactly `amount`, exact-out sell receives exactly `amount`.
            assertEq(leg, amount, "trader's WETH leg is exact");
            assertEq(fee, amount * bps / 1e4, "fee on the specified leg");
        } else if (buy) {
            assertEq(fee, (leg - fee) * bps / (1e4 - bps), "exact-out buy: pool's WETH in x bps/(1e4-bps)");
        } else {
            assertEq(fee, (leg + fee) * bps / (1e4 + bps), "exact-in sell: pool's WETH out x bps/(1e4+bps)");
        }
    }

    function _allCases(uint256 bps) internal {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; i++) {
            (bool buy, bool exactIn) = (i < 2, i % 2 == 0);
            _case(buy, exactIn, (buy || exactIn) ? 1e18 : 0.5e18, bps);
            vm.revertToState(snap);
        }
    }

    /// @return leg the WETH the trader paid (buy) or received (sell)
    /// @return fee the WETH the vault received
    function _swap(Actor via, bool buy, bool exactIn, uint256 amount) internal returns (uint256 leg, uint256 fee) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == WETH);
        uint256 w0 = weth.balanceOf(TRADER);
        uint256 v0 = weth.balanceOf(address(vault));
        vm.prank(TRADER);
        via.swap(key, zeroForOne, exactIn ? -int256(amount) : int256(amount));
        uint256 w1 = weth.balanceOf(TRADER);
        leg = buy ? w0 - w1 : w1 - w0;
        fee = weth.balanceOf(address(vault)) - v0;
    }

    function _expectNoFeeTake() internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.take.selector, WETH, address(vault)), 0);
    }

    function _wrapped(bytes4 hookSelector, bytes4 err) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            HOOK,
            hookSelector,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _key(address coin_, int24 spacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = coin_ < WETH ? (coin_, WETH) : (WETH, coin_);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, spacing, IHooks(HOOK));
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }
}

contract LauncherHookCoinToken0Test is LauncherHookBase {
    function _coinAddress() internal pure override returns (address) {
        return 0x1111111111111111111111111111111111111111;
    }
}

contract LauncherHookCoinToken1Test is LauncherHookBase {
    function _coinAddress() internal pure override returns (address) {
        return 0xC0C0c0c0C0C0c0c0c0C0c0C0C0C0C0C0C0C0c0c0;
    }
}
