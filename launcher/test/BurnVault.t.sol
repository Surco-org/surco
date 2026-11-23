// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {
    MockWETH,
    MockCbEth,
    MockPinto,
    MockPump,
    MockWell,
    MockV3Pool,
    MockSwapRouter,
    MockSiloWithConvert
} from "./mocks/LauncherMocks.sol";
import {RouteHarness} from "./fork/PintoRoute.t.sol";
import {Actor} from "./LauncherHook.t.sol";
import {VaultBase} from "../src/VaultBase.sol";
import {BurnVault} from "../src/BurnVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {
    WETH,
    CBETH,
    PINTO,
    PINTO_DIAMOND,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    V3_WETH_CBETH_POOL,
    SWAP_ROUTER02,
    TICK_SPACING,
    LP_FEE,
    MAX_BUYBACK_PINTO,
    EMA_WINDOW,
    SUPPLY
} from "../src/Constants.sol";

/// BurnVault with a handle on _deposit, so tests can put principal in the Silo directly.
contract BurnHarness is BurnVault {
    constructor(LaunchToken coin, IPoolManager manager, LauncherHook hook)
        BurnVault(coin, address(0x5AFE), address(0xC0FFEE), 0, manager, hook)
    {}

    /// Deposits `amount` Pinto the vault already holds.
    function deposit(uint256 amount) external {
        _deposit(amount);
    }
}

/// The hook's factory: adds liquidity on any tick range, paid by the caller.
contract RangeLP is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function add(PoolKey calldata key, int24 lo, int24 hi, uint256 liquidity) external {
        manager.unlock(abi.encode(msg.sender, key, lo, hi, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (address payer, PoolKey memory key, int24 lo, int24 hi, uint256 liquidity) =
            abi.decode(data, (address, PoolKey, int24, int24, uint256));
        (BalanceDelta d,) =
            manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lo, hi, int256(liquidity), 0), "");
        _pay(key.currency0, d.amount0(), payer);
        _pay(key.currency1, d.amount1(), payer);
        return "";
    }

    function _pay(Currency currency, int128 amount, address payer) internal {
        if (amount >= 0) return;
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint128(-amount));
        manager.settle();
    }
}

/// @dev Every test runs with the coin on both sides of WETH (the two concrete contracts at the bottom).
abstract contract BurnVaultBase is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK = address(uint160(0x2AEC | (uint256(0xB0B) << 148)));
    address internal constant SAFE = address(0x5AFE);
    address internal constant KEEPER = address(0xBEEF);
    address internal constant TRADER = address(0x7AADE);
    int24 internal constant START_TICK = 1000; // token1 per token0 = 1.0001^1000 ~= 1.10517

    MockSiloWithConvert internal silo = MockSiloWithConvert(PINTO_DIAMOND);
    MockPinto internal pinto = MockPinto(PINTO);
    MockWETH internal weth = MockWETH(WETH);
    IPoolManager internal manager;
    LauncherHook internal hook;
    LaunchToken internal coin;
    BurnHarness internal vault;
    RangeLP internal hookFactory;
    Actor internal router;
    PoolKey internal key;
    PoolId internal id;

    function _coinAddress() internal pure virtual returns (address);

    function setUp() public {
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);
        vm.etch(PINTO_DIAMOND, address(new MockSiloWithConvert()).code);

        // VaultBaseTest's market: 690k Pinto / 6.5 cbETH, spot = EMA, router spot = TWAP, both directions.
        MockWell(CBETH_WELL).setReserves(690_000e6, 6.5 ether);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 690_000e6, 6.5 ether);
        pinto.mint(CBETH_WELL, 690_000e6);
        MockCbEth(CBETH).mint(CBETH_WELL, 6.5 ether);
        MockV3Pool(V3_WETH_CBETH_POOL).setTick(1345);
        RouteHarness h = new RouteHarness();
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, h.cbEthForWeth(1 ether));
        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, h.wethForCbEth(1 ether));
        MockCbEth(CBETH).mint(SWAP_ROUTER02, 100 ether);
        weth.mint(SWAP_ROUTER02, 10_000 ether);

        // The coin's pool: local PoolManager + the hook at a flag address (LauncherHookTest's setup).
        manager = new PoolManager(address(this));
        hookFactory = new RangeLP(manager);
        router = new Actor(manager);
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(hookFactory), WETH), HOOK);
        hook = LauncherHook(HOOK);
        weth.mint(address(this), 10_000e18);
        weth.approve(address(hookFactory), type(uint256).max);
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        (coin, vault, key) = _launch(_coinAddress(), START_TICK, lo, hi, 1_000e18);
        id = key.toId();
        weth.mint(address(manager), 1_000e18); // R9: a trader's fee take is paid from the manager's float

        weth.mint(TRADER, 1_000e18);
        coin.transfer(TRADER, 1_000e18);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ---- buyback ----

    function test_buyback_noop_below_peg() public {
        _seed();
        _depositAt(1, 1_000e6);
        silo.setPlant(100e6, 3);
        silo.setBelow(true);
        vm.expectCall(PINTO_DIAMOND, abi.encodeCall(MockSiloWithConvert.plant, ()), 0);

        vm.prank(KEEPER);
        vault.buyback(MAX_BUYBACK_PINTO);

        assertEq(silo.plantBeans(), 100e6, "plant() not called");
        assertEq(vault.siloPinto(), 1_000e6);
        assertEq(vault.yieldPinto(), 0);
        assertEq(coin.totalSupply(), SUPPLY);
        assertEq(pinto.balanceOf(KEEPER), 0);
    }

    function test_buyback_burns_all_bought() public {
        _seed();
        _depositAt(1, 1_000e6);
        silo.setPlant(100e6, 3);
        uint256 supply0 = coin.totalSupply();
        uint256 poolCoins0 = coin.balanceOf(address(manager));

        vm.recordLogs();
        vm.prank(KEEPER);
        vault.buyback(MAX_BUYBACK_PINTO);

        uint256 burned = supply0 - coin.totalSupply();
        assertGt(burned, 0, "coins burned");
        assertEq(poolCoins0 - coin.balanceOf(address(manager)), burned, "every coin bought is burned");
        assertEq(coin.balanceOf(address(vault)), 0, "vault keeps no coins");
        assertEq(pinto.balanceOf(address(vault)), 0, "vault keeps no Pinto");
        assertEq(pinto.balanceOf(KEEPER), 0.5e6, "tip: TIP_BPS of the batch, in Pinto");
        assertEq(vault.yieldPinto(), 0);
        assertEq(vault.siloPinto(), 1_000e6);
        _assertTally();

        (uint256 pintoIn, uint256 coinsBurned, uint256 tip) = _boughtBack();
        assertEq(pintoIn, 99.5e6);
        assertEq(coinsBurned, burned);
        assertEq(tip, 0.5e6);

        // The coins match the pool's price for the WETH the route produced (tiny trade, no impact to speak of).
        uint256 wethPaid = _wethIntoPool();
        uint256 expected = address(coin) < WETH ? wethPaid * 1e5 / 110517 : wethPaid * 110517 / 1e5;
        assertApproxEqRel(burned, expected, 0.001e18, "price at the start tick");
    }

    /// Principal on stems older, equal to and newer than the planted stem: only the planted Pinto leaves the Silo.
    function test_buyback_principal_untouched() public {
        _seed();
        _depositAt(1, 1_000e6);
        _depositAt(3, 200e6); // same stem plant() will use
        _depositAt(5, 300e6); // newer than the planted stem
        silo.setPlant(100e6, 3);
        uint256 principal = vault.siloPinto() - vault.yieldPinto();

        vm.prank(KEEPER);
        vault.buyback(MAX_BUYBACK_PINTO);

        assertEq(vault.siloPinto() - vault.yieldPinto(), principal, "principal unchanged");
        assertEq(vault.siloPinto(), 1_500e6);
        assertEq(silo.deposits(address(vault), 1), 1_000e6);
        assertEq(silo.deposits(address(vault), 3), 200e6, "only the planted part of stem 3 left");
        assertEq(silo.deposits(address(vault), 5), 300e6, "the newest deposit is principal: untouched");
        _assertTally();
    }

    function test_seed_is_principal_not_yield() public {
        _seed(); // the file's market helper, not the vault's seed()
        _depositAt(1, 1_000e6);
        silo.setNextStem(3);
        pinto.mint(address(vault), 400e6);
        vault.seed();
        assertEq(vault.yieldPinto(), 0, "seed is not yield");
        silo.setPlant(100e6, 3);
        vm.prank(KEEPER);
        vault.buyback(MAX_BUYBACK_PINTO);
        assertEq(vault.siloPinto() - vault.yieldPinto(), 1_400e6, "principal = converted + seeded, untouched");
        assertEq(silo.deposits(address(vault), 3), 400e6, "only the planted part of stem 3 was spent");
        _assertTally();
    }

    function test_buyback_pays_no_hook_fee() public {
        _seed(); // a trader's swap: the vault holds its fee, unsplit
        vault.split();
        uint256 pending = vault.pendingPintoWeth();
        assertGt(pending, 0);
        uint256 safe0 = weth.balanceOf(SAFE);
        silo.setPlant(100e6, 3);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.take.selector, WETH, address(vault)), 0);

        vm.prank(KEEPER);
        vault.buyback(MAX_BUYBACK_PINTO);

        assertEq(weth.balanceOf(address(vault)), vault.pendingPintoWeth(), "the route's WETH is all spent");
        assertEq(vault.pendingPintoWeth(), pending);
        vault.split();
        assertEq(weth.balanceOf(SAFE), safe0, "nothing new for split() to pay out");
    }

    /// A big swap earlier in the block moves the tick past MAX_TICK_DRIFT from the EMA, either way: revert. The pool
    /// sat idle a whole window first, so a projection from the stale EMA would reach the pushed tick; but the push
    /// itself updated the EMA in this block (dt = 0), so the projected EMA is the pre-push tick (R22).
    function test_buyback_reverts_when_pool_pushed() public {
        _seed();
        silo.setPlant(100e6, 3);
        vm.warp(block.timestamp + EMA_WINDOW);
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            bool buy = i == 0;
            _swap(buy, buy ? 100e18 : 150e18);
            int256 drift = int256(_tick()) - hook.emaTick(id);
            assertGt(drift < 0 ? -drift : drift, 300, "pushed past MAX_TICK_DRIFT");
            vm.expectRevert(BurnVault.TickDrift.selector);
            vault.buyback(MAX_BUYBACK_PINTO);
            vm.revertToState(snap);
        }
    }

    /// The min-out is the EMA price less COIN_TOL_BPS, so a batch's own price impact is bounded by it: ~2% passes,
    /// ~4% reverts. A quote on the wrong side of the price would fail one of the two in one sort order.
    function test_buyback_min_out_from_ema() public {
        _seed();
        silo.setPlant(MAX_BUYBACK_PINTO, 3);
        RouteHarness h = new RouteHarness();
        // 2,000 Pinto -> ~0.0188 cbETH; the router pays 1000x (then 2000x) the TWAP, ~21 (~43) WETH, into ~1,000 WETH.
        uint256 snap = vm.snapshotState();
        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, h.wethForCbEth(1000 ether));
        vault.buyback(MAX_BUYBACK_PINTO);
        vm.revertToState(snap);

        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, h.wethForCbEth(2000 ether));
        vm.expectRevert(BurnVault.Slippage.selector);
        vault.buyback(MAX_BUYBACK_PINTO);
    }

    /// R22: a big legitimate trade, then silence. The tick has held since, so the EMA projected to now catches up
    /// with no further swap: still refused a minute later, accepted after a whole window.
    function test_buyback_after_big_trade_and_silence() public {
        _seed();
        silo.setPlant(100e6, 3);
        vm.warp(block.timestamp + 2);
        _swap(true, 100e18);
        uint256 tradeTs = block.timestamp;
        int256 gap = int256(_tick()) - hook.emaTick(id);
        assertGt(gap < 0 ? -gap : gap, 1000, "the stored EMA lags far behind");

        vm.warp(tradeTs + 60);
        vm.expectRevert(BurnVault.TickDrift.selector);
        vault.buyback(MAX_BUYBACK_PINTO);

        vm.warp(tradeTs + EMA_WINDOW);
        assertEq(hook.coin(id).emaTs, tradeTs, "no swap since the trade");
        uint256 supply0 = coin.totalSupply();
        vault.buyback(MAX_BUYBACK_PINTO);
        assertLt(coin.totalSupply(), supply0, "bought and burned");
    }

    /// R21: a launch-shaped pool (the whole supply single-sided from a 10 ETH FDV) with Pinto at peg. A 2,000 Pinto
    /// batch (~0.68 WETH, ~6% impact on ~10 ETH) fails the min-out; the keeper sizes it down and it goes through.
    function test_buyback_young_pool_sized_by_caller() public {
        (BurnHarness young,) = _youngPool();
        _pegMarket();
        silo.setPlant(MAX_BUYBACK_PINTO, 3);

        vm.expectRevert(BurnVault.Slippage.selector);
        young.buyback(MAX_BUYBACK_PINTO);

        LaunchToken youngCoin = young.coin();
        young.buyback(500e6);
        assertEq(young.yieldPinto(), 1_500e6, "500 spent, the rest waits");
        assertLt(youngCoin.totalSupply(), SUPPLY, "burned");
        assertEq(youngCoin.balanceOf(address(young)), 0);
    }

    function test_buyback_caller_batch() public {
        _seed();
        silo.setPlant(2_500e6, 3);
        vm.expectRevert(BurnVault.ZeroBatch.selector);
        vault.buyback(0);

        vm.prank(KEEPER);
        vault.buyback(300e6);
        assertEq(vault.yieldPinto(), 2_200e6, "maxPinto binds below the cap");
        assertEq(pinto.balanceOf(KEEPER), 1.5e6);
    }

    function test_buyback_batch_capped() public {
        _seed();
        _depositAt(1, 1_000e6);
        silo.setPlant(2_500e6, 3);

        vm.prank(KEEPER);
        vault.buyback(type(uint256).max);
        assertEq(vault.yieldPinto(), 500e6, "batch capped at MAX_BUYBACK_PINTO");
        assertEq(pinto.balanceOf(KEEPER), MAX_BUYBACK_PINTO / 200, "tip on the capped batch");
        assertEq(silo.deposits(address(vault), 3), 500e6);

        // Next season: 1,000 more planted on stem 4. Batch = 1,500, newest planted stem first.
        vm.warp(block.timestamp + 2);
        silo.setPlant(1_000e6, 4);
        vm.prank(KEEPER);
        vault.buyback(MAX_BUYBACK_PINTO);
        assertEq(vault.yieldPinto(), 0);
        assertEq(silo.deposits(address(vault), 3), 0);
        assertEq(silo.deposits(address(vault), 4), 0);
        assertEq(vault.siloPinto(), 1_000e6, "principal stays");
        _assertTally();

        vm.expectRevert(VaultBase.NothingPending.selector);
        vault.buyback(MAX_BUYBACK_PINTO);
    }

    /// emaTick reads 0 until the pool's first swap, so there is no price to guard with yet.
    function test_buyback_reverts_before_first_swap() public {
        silo.setPlant(100e6, 3);
        vm.expectRevert(BurnVault.NoEma.selector);
        vault.buyback(MAX_BUYBACK_PINTO);
    }

    /// The quote is symmetric: tick t with the coin as token1 prices like tick -t with the coin as token0. At
    /// |t| = 500,000 one side takes OracleLibrary's sqrtP > 2^128 branch and the other does not.
    function test_coins_for_weth_both_branches() public pure {
        int24[3] memory ticks = [int24(1000), 200_000, 500_000];
        for (uint256 i; i < 3; i++) {
            assertApproxEqRel(
                PriceGuard.coinsForWeth(1e18, ticks[i], false), PriceGuard.coinsForWeth(1e18, -ticks[i], true), 1e9
            );
        }
        assertApproxEqRel(PriceGuard.coinsForWeth(1e18, 1000, false), 1.10517e18, 1e14, "1.0001^1000");
    }

    // ---- wiring ----

    function test_set_pool_key_factory_once() public {
        vm.prank(KEEPER);
        vm.expectRevert(BurnVault.OnlyFactory.selector);
        vault.setPoolKey(key);
        vm.expectRevert(BurnVault.KeySet.selector);
        vault.setPoolKey(key);

        BurnHarness fresh = new BurnHarness(coin, manager, hook);
        vm.expectRevert(BurnVault.BadKey.selector); // registered to the other vault
        fresh.setPoolKey(key);
    }

    function test_unlock_callback_only_manager() public {
        vm.expectRevert(BurnVault.OnlyManager.selector);
        vault.unlockCallback(abi.encode(uint256(1)));
    }

    // ---- helpers ----

    /// A coin, its Burn vault and its pool at `startTick`, with `liquidity` on [lo, hi] from this contract.
    function _launch(address at, int24 startTick, int24 lo, int24 hi, uint256 liquidity)
        internal
        returns (LaunchToken c, BurnHarness v, PoolKey memory k)
    {
        deployCodeTo("LaunchToken.sol:LaunchToken", abi.encode("Coin", "COIN", "", "", address(this)), at);
        c = LaunchToken(at);
        v = new BurnHarness(c, manager, hook);
        (address c0, address c1) = at < WETH ? (at, WETH) : (WETH, at);
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, TICK_SPACING, IHooks(HOOK));
        vm.startPrank(address(hookFactory));
        hook.register(k, address(v), 100);
        manager.initialize(k, TickMath.getSqrtPriceAtTick(startTick));
        vm.stopPrank();
        v.setPoolKey(k);
        c.approve(address(hookFactory), type(uint256).max);
        hookFactory.add(k, lo, hi, liquidity);
    }

    /// The launch shape: 99% of supply single-sided from 1e-8 WETH per coin (FDV ~10 ETH, tick +-184,200 on the
    /// 200 grid) toward a dearer coin, so the virtual WETH reserve at launch is ~10 ETH. The EMA is seeded.
    function _youngPool() internal returns (BurnHarness v, PoolKey memory k) {
        address at = address(uint160(_coinAddress()) + 1);
        bool coinIs0 = at < WETH;
        int24 start = coinIs0 ? int24(-184_200) : int24(184_200);
        uint160 sp = TickMath.getSqrtPriceAtTick(start);
        uint256 coins = SUPPLY * 99 / 100;
        // token0 single-sided lies above the price: amount0 ~= L * 2^96 / sqrtP. token1 lies below: L * sqrtP / 2^96.
        (int24 lo, int24 hi, uint256 liquidity) = coinIs0
            ? (start, TickMath.maxUsableTick(TICK_SPACING), FullMath.mulDiv(coins, sp, 1 << 96))
            : (TickMath.minUsableTick(TICK_SPACING), start, FullMath.mulDiv(coins, 1 << 96, sp));
        (, v, k) = _launch(at, start, lo, hi, liquidity);
        bool zeroForOne = Currency.unwrap(k.currency0) == WETH;
        vm.prank(TRADER);
        router.swap(k, zeroForOne, -1e15);
    }

    /// Pinto at peg: ~3,333 Pinto per cbETH (690k Pinto / 207 cbETH), spot = EMA.
    function _pegMarket() internal {
        MockWell(CBETH_WELL).setReserves(690_000e6, 207 ether);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 690_000e6, 207 ether);
        MockCbEth(CBETH).mint(CBETH_WELL, 200.5 ether);
    }

    /// A trader's small buy: seeds the hook's EMA at START_TICK and pays the vault a fee.
    function _seed() internal {
        _swap(true, 1e15);
    }

    function _swap(bool buy, uint256 amount) internal {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == WETH);
        vm.prank(TRADER);
        router.swap(key, zeroForOne, -int256(amount));
    }

    function _depositAt(int96 stem, uint256 amount) internal {
        silo.setNextStem(stem);
        pinto.mint(address(vault), amount);
        vault.deposit(amount);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    /// The tally equals what the Silo holds for the vault.
    function _assertTally() internal view {
        assertEq(silo.held(address(vault)), vault.siloPinto(), "silo holds the tally");
    }

    function _boughtBack() internal view returns (uint256 pintoIn, uint256 coins, uint256 tip) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == BurnVault.BoughtBack.selector) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        revert("no BoughtBack");
    }

    /// The WETH the route produced for the last buyback, recomputed from the mocks: the well at its new reserves
    /// paid cbETH for 99.5 Pinto, and the router pays a fixed rate.
    function _wethIntoPool() internal view returns (uint256) {
        uint256[] memory r = MockWell(CBETH_WELL).getReserves();
        uint256 cbOut = 6.5 ether - r[1];
        return cbOut * MockSwapRouter(SWAP_ROUTER02).rate(CBETH, WETH) / 1e18;
    }
}

contract BurnVaultCoinToken0Test is BurnVaultBase {
    function _coinAddress() internal pure override returns (address) {
        return 0x1111111111111111111111111111111111111111;
    }
}

contract BurnVaultCoinToken1Test is BurnVaultBase {
    function _coinAddress() internal pure override returns (address) {
        return 0xC0C0c0c0C0C0c0c0c0C0c0C0C0C0C0C0C0C0c0c0;
    }
}
