// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
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
import {LauncherFactory} from "../src/LauncherFactory.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {VaultBase} from "../src/VaultBase.sol";
import {RedeemVault} from "../src/RedeemVault.sol";
import {BurnVault} from "../src/BurnVault.sol";
import {FeeMath} from "../src/FeeMath.sol";
import {
    WETH,
    CBETH,
    PINTO,
    PINTO_DIAMOND,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    V3_WETH_CBETH_POOL,
    SWAP_ROUTER02,
    SUPPLY,
    TICK_SPACING,
    LP_FEE,
    LAUNCH_FEE,
    MAX_CONVERT_WETH,
    MAX_BUYBACK_PINTO,
    MERGE_ABOVE_STEMS,
    EMA_WINDOW,
    REDEEM_FEE_BPS,
    WELL_TOL_BPS
} from "../src/Constants.sol";

address constant HOOK = address(uint160(0x2AEC | (uint256(0xB0B) << 148)));
address constant SAFE = address(0x5AFE);
address constant CREATOR = address(0xC0FFEE);
address constant LAUNCHER = address(0x1A0C4);
address constant KEEPER = address(0xBEEF);
uint16 constant FEE_BPS = 100;
uint16 constant CREATOR_BPS = 1000;
uint256 constant WELL_PINTO = 690_000e6;
uint256 constant WELL_CB = 6.5 ether;

/// @dev Random trades (both directions, exact-in and exact-out, max and exact allowances), burns, splits, converts,
///      redeems / claims / merges (Redeem) or buybacks (Burn), clock and season moves, peg toggles, cbETH-well moves,
///      extra launches and stray funds, against the real PoolManager, hook, factory and vault, with the Pinto side
///      mocked at the Constants addresses (R2). Every ghost below is measured from balances outside the vault, never
///      read from the vault's own books.
contract LauncherHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    LauncherFactory public immutable factory;
    LauncherHook public immutable hook;
    LaunchToken public immutable coin;
    address public immutable vault;
    bool public immutable coinIs0;
    bool public immutable redeemMode;
    Actor public immutable router;
    PoolId public immutable id;
    int24 public immutable startTick;
    uint128 public immutable lockedLiquidity;
    uint256 public immutable launchedAt; // the setUp launch's timestamp: the toll clock, read from no contract

    MockWETH internal constant weth = MockWETH(WETH);
    MockPinto internal constant pinto = MockPinto(PINTO);
    MockSiloWithConvert internal constant silo = MockSiloWithConvert(PINTO_DIAMOND);

    PoolKey internal key;
    address[3] internal actors = [address(0xA11CE), address(0xB0B0), address(0xCA401)];
    int96 public stem = 1;
    address[] public extraCoins;

    // ---- ghosts (R5, R6) ----
    uint256 public feesIn; // WETH the hook sent the vault
    uint256 public safePaid;
    uint256 public creatorPaid;
    uint256 public tipsPaid; // WETH tips to convert callers
    uint256 public wethConverted; // WETH the route pulled in convert()
    uint256 public pintoDeposited; // Pinto the well paid out in convert(), plus Pinto seeded
    uint256 public pintoSeeded; // Pinto sent to the vault and booked by seed()
    uint256 public pintoPlanted; // beans the Silo planted for the vault
    uint256 public pintoRedeemed; // Pinto paid to redeemers
    uint256 public pintoBoughtBack; // planted Pinto spent by buyback (into the well + the Pinto tip)
    uint256 public strayWeth;
    uint256 public strayEth;
    uint256 public feesSplit; // fees already split (R26): fresh = feesIn - feesSplit
    uint256 public pendingGhost; // R26: += the Pinto share of each split, -= each converted batch

    // ---- success counters: a path that only ever reverts shows up here, not as a pass ----
    uint256 public okConvert;
    uint256 public okAutoMerge; // a convert whose merge collapsed the finished stems
    uint256 public okMerge; // a merge() that shrank the stem list
    uint256 public okClaim; // a claim that planted beans
    uint256 public okRedeem;
    uint256 public okBuyback; // a buyback at peg that bought and burned
    uint256 public okSeed;

    struct Snap {
        uint256 safe;
        uint256 creator;
        uint256 keeper;
        uint256 router;
        uint256 well;
    }

    // ---- the state before the last handler call ----
    uint256 public prevSupply;
    uint256 public prevSilo;
    uint256 public prevPrincipal;

    modifier track() {
        prevSupply = coin.totalSupply();
        prevSilo = VaultBase(vault).siloPinto();
        prevPrincipal = redeemMode ? 0 : prevSilo - BurnVault(vault).yieldPinto();
        _;
    }

    constructor(LauncherFactory factory_, LaunchToken coin_, address vault_, bool redeemMode_, uint256 launchedAt_) {
        factory = factory_;
        launchedAt = launchedAt_;
        manager = factory_.manager();
        hook = factory_.hook();
        coin = coin_;
        vault = vault_;
        redeemMode = redeemMode_;
        coinIs0 = address(coin_) < WETH;
        router = new Actor(manager);
        key = PoolKey(
            Currency.wrap(coinIs0 ? address(coin_) : WETH),
            Currency.wrap(coinIs0 ? WETH : address(coin_)),
            LP_FEE,
            TICK_SPACING,
            IHooks(address(hook))
        );
        id = key.toId();
        startTick = coinIs0 ? factory_.startTick0() : -factory_.startTick0();
        (int24 lo, int24 hi) = coinIs0
            ? (startTick, TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), startTick);
        lockedLiquidity =
            manager.getPositionLiquidity(id, Position.calculatePositionKey(address(factory_), lo, hi, 0));
        feesIn = weth.balanceOf(vault_); // the creator's first buy
        for (uint256 i; i < 3; i++) {
            weth.mint(actors[i], 1_000_000 ether);
            vm.prank(actors[i]);
            weth.approve(address(router), type(uint256).max);
        }
        prevSupply = coin_.totalSupply();
    }

    // ---- trades ----

    /// Exact-in: `amount` WETH. Exact-out: `amount` coins.
    function buy(uint256 who, uint256 amount, bool exactOut) external track {
        address a = _actor(who);
        if (exactOut) {
            uint256 pool = coin.balanceOf(address(manager));
            if (pool < 10) return;
            amount = bound(amount, 1, pool / 20);
            _swap(a, true, int256(amount), 0);
        } else {
            amount = bound(amount, 1, 20 ether);
            _swap(a, true, -int256(amount), amount);
        }
    }

    /// Exact-in: `amount` coins. Exact-out: `amount` WETH, at most half the WETH the pool holds (no partial fill).
    /// `maxAllowance` false approves exactly what the router may pull, so transferFrom's finite path runs.
    function sell(uint256 who, uint256 amount, bool exactOut, bool maxAllowance) external track {
        address a = _actor(who);
        uint256 bal = coin.balanceOf(a);
        if (bal == 0) return;
        if (exactOut) {
            uint256 poolWeth = _poolWeth();
            if (poolWeth < 2) return;
            amount = bound(amount, 1, poolWeth / 2);
            _approve(a, address(router), maxAllowance ? type(uint256).max : bal);
            uint256 allowance0 = coin.allowance(a, address(router));
            try this.swapAs(a, false, int256(amount), amount) {}
            catch (bytes memory e) {
                // The trader's coins (or the exact allowance of them) cannot buy that much WETH.
                bytes4 s = bytes4(e);
                require(s == LaunchToken.Balance.selector || s == LaunchToken.Allowance.selector, "sell reverted");
                return;
            }
            _assertAllowanceSpent(a, allowance0, bal - coin.balanceOf(a));
        } else {
            amount = bound(amount, 1, bal);
            _approve(a, address(router), maxAllowance ? type(uint256).max : amount);
            uint256 allowance0 = coin.allowance(a, address(router));
            _swap(a, false, -int256(amount), 0);
            assertEq(bal - coin.balanceOf(a), amount, "exact-in sell takes exactly the coins");
            _assertAllowanceSpent(a, allowance0, amount);
        }
    }

    /// A holder burns part of, or exactly, their whole balance.
    function burn(uint256 who, uint256 amount, bool all) external track {
        address a = _actor(who);
        uint256 bal = coin.balanceOf(a);
        amount = all ? bal : bound(amount, 0, bal);
        vm.prank(a);
        coin.burn(amount);
        assertEq(coin.balanceOf(a), bal - amount);
    }

    // ---- vault ----

    function split() external track {
        uint256 fresh = feesIn - feesSplit;
        Snap memory b = _snap();
        VaultBase(vault).split();
        _noteSplit(b, fresh);
    }

    /// A batch of at least 1e9 wei with the cbETH well on its EMA must convert; any other revert must be explained
    /// by the state (nothing pending, a dust batch, the well pushed off its EMA).
    function convert() external track {
        uint256 fresh = feesIn - feesSplit;
        (,, uint256 share) = FeeMath.split(fresh, CREATOR_BPS);
        uint256 pending = pendingGhost + share;
        uint256 batch = pending < MAX_CONVERT_WETH ? pending : MAX_CONVERT_WETH;
        uint256 finished0 = redeemMode ? _finishedStems() : 0;
        Snap memory b = _snap();
        vm.prank(KEEPER);
        try VaultBase(vault).convert() {}
        catch (bytes memory e) {
            bytes4 s = bytes4(e);
            require(batch < 1e9 || !_wellOnEma(), "clean convert reverted");
            require(
                (s == VaultBase.NothingPending.selector && batch == 0)
                    || (s == VaultBase.ZeroOut.selector && batch < 1e9)
                    || (s == MockWell.SlippageOut.selector && !_wellOnEma()),
                "convert reverted"
            );
            return;
        }
        _noteSplit(b, fresh);
        uint256 tip = _keeper() - b.keeper;
        uint256 routed = weth.balanceOf(SWAP_ROUTER02) - b.router;
        assertEq(tip, FeeMath.tip(batch), "tip = TIP_BPS of the batch");
        assertEq(tip + routed, batch, "the batch is the tip plus what the route took");
        pendingGhost -= batch;
        tipsPaid += tip;
        wethConverted += routed;
        pintoDeposited += b.well - pinto.balanceOf(CBETH_WELL);
        okConvert++;
        if (redeemMode) {
            // The mock germinates stems >= tip - 1, so at most two are germinating; above MERGE_ABOVE_STEMS the
            // auto-merge folds every finished stem into one (its toStem lies below the germinating ones).
            assertLe(RedeemVault(vault).stems().length, MERGE_ABOVE_STEMS, "auto-merge keeps <= 3 stems");
            if (_finishedStems() < finished0) okAutoMerge++;
        }
    }

    /// Redeem: burn `amount` of the holder's coins for their share, with an exact or max allowance.
    function redeem(uint256 who, uint256 amount, bool maxAllowance) external track {
        address a = _actor(who);
        uint256 bal = coin.balanceOf(a);
        amount = bound(amount, 0, bal);
        _approve(a, vault, maxAllowance ? type(uint256).max : amount);
        uint256 gross = amount * VaultBase(vault).siloPinto() / coin.totalSupply();
        uint256 expected = gross - (gross * REDEEM_FEE_BPS + 9_999) / 1e4;
        uint256 p0 = pinto.balanceOf(a);
        vm.prank(a);
        try RedeemVault(vault).redeem(amount, expected, a) returns (uint256 out) {
            assertEq(out, expected, "share less the fee, rounded for the vault");
            assertEq(pinto.balanceOf(a) - p0, out, "paid what it said");
            assertEq(bal - coin.balanceOf(a), amount, "coins taken");
            if (!maxAllowance) assertEq(coin.allowance(a, vault), 0, "exact allowance used up");
            pintoRedeemed += out;
            okRedeem++;
        } catch (bytes memory e) {
            require(bytes4(e) == VaultBase.ZeroOut.selector && expected == 0, "redeem reverted");
        }
    }

    function claim(uint256 beans) external track {
        silo.setPlant(bound(beans, 0, 10_000e6), stem);
        uint256 p0 = silo.plantBeans();
        RedeemVault(vault).claim();
        uint256 planted = p0 - silo.plantBeans();
        pintoPlanted += planted;
        if (planted != 0) okClaim++;
    }

    function merge() external track {
        uint256 n0 = RedeemVault(vault).stems().length;
        RedeemVault(vault).merge();
        assertLe(_finishedStems(), 1, "merge leaves at most one finished stem");
        if (RedeemVault(vault).stems().length < n0) okMerge++;
    }

    /// Burn: plant `beans`, then buy back with a keeper-sized batch. At peg, with a batch of at least 1 Pinto, the EMA
    /// a whole window old (projected onto the tick: no drift) and the well on its EMA, it must succeed.
    function buyback(uint256 beans, uint256 maxPinto) external track {
        beans = bound(beans, 0, 5_000e6);
        silo.setPlant(beans, stem);
        maxPinto = bound(maxPinto, 0, 3_000e6);
        uint256 batch = BurnVault(vault).yieldPinto() + beans;
        if (batch > MAX_BUYBACK_PINTO) batch = MAX_BUYBACK_PINTO;
        if (batch > maxPinto) batch = maxPinto;
        bool atPeg = !silo.below();
        bool clean = atPeg && batch >= 1e6 && _emaSettled() && _wellOnEma();
        uint256 p0 = silo.plantBeans();
        Snap memory b = _snap();
        uint256 vw0 = weth.balanceOf(vault);
        uint256 supply0 = coin.totalSupply();
        vm.prank(KEEPER);
        try BurnVault(vault).buyback(maxPinto) {
            if (atPeg) {
                assertLt(coin.totalSupply(), supply0, "a buyback at peg burns coins");
                okBuyback++;
            }
        } catch (bytes memory e) {
            bytes4 s = bytes4(e);
            require(!clean, "clean buyback reverted");
            require(
                (s == BurnVault.ZeroBatch.selector && maxPinto == 0)
                    || (s == VaultBase.NothingPending.selector && batch == 0)
                    || (s == VaultBase.ZeroOut.selector && batch < 1e6) || s == BurnVault.TickDrift.selector
                    || s == BurnVault.Slippage.selector || s == MockWell.SlippageOut.selector,
                "buyback reverted"
            );
        }
        pintoPlanted += p0 - silo.plantBeans();
        pintoBoughtBack += pinto.balanceOf(CBETH_WELL) - b.well + _keeper() - b.keeper;
        assertEq(weth.balanceOf(vault), vw0, "buyback leaves the vault's WETH as it was");
        assertEq(coin.balanceOf(vault), 0, "every coin bought is burned");
    }

    // ---- the world ----

    function warp(uint256 secs) external track {
        secs = bound(secs, 1, 2 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 2 + 1);
    }

    /// Pinto's season: a new stem tip; the last two seasons' stems germinate.
    function newSeason() external track {
        stem++;
        silo.setNextStem(stem);
        silo.setGerminatingStem(stem - 1);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1800);
    }

    function togglePeg() external track {
        silo.setBelow(!silo.below());
    }

    /// The cbETH well's spot moves up to ±6% from its pump EMA (0 = back on it); past ~WELL_TOL_BPS (+ the
    /// WELL_FEE_BPS the quote deducts) the route's guard refuses.
    function nudgeWell(int256 bps) external track {
        bps = bound(bps, -600, 600);
        MockWell(CBETH_WELL).setReserves(uint256(int256(WELL_PINTO) * (1e4 + bps) / 1e4), WELL_CB);
    }

    /// Another coin, any mode, fee, creator share, first buy and sort order. Capped so a run stays fast.
    function launch(uint256 seed, uint256 value) external track {
        if (extraCoins.length >= 4) return;
        value = bound(value, 0, 5 ether);
        LauncherFactory.Params memory p = LauncherFactory.Params({
            name: "Other",
            symbol: "OTHER",
            imageURI: "",
            metadataURI: "",
            mode: seed % 2 == 0 ? LauncherFactory.Mode.Redeem : LauncherFactory.Mode.Burn,
            feeBps: uint16(bound(seed >> 8, 30, 300)),
            creatorBps: uint16(bound(seed >> 24, 0, 2000)),
            creatorPayout: address(uint160(0xC0DE00 + extraCoins.length))
        });
        vm.deal(LAUNCHER, value + LAUNCH_FEE);
        vm.prank(LAUNCHER);
        (address c,,) = factory.launch{value: value + LAUNCH_FEE}(p);
        extraCoins.push(c);
    }

    /// Someone sends the factory WETH or ETH. It must never block a launch (R24) and is never touched.
    function stray(uint256 w, uint256 e) external track {
        w = bound(w, 0, 1 ether);
        e = bound(e, 0, 1 ether);
        weth.mint(address(factory), w);
        vm.deal(address(factory), address(factory).balance + e);
        strayWeth += w;
        strayEth += e;
    }

    /// Someone sends the vault Pinto by plain transfer, then anyone books it with seed(). Seeded Pinto is principal.
    function seed(uint256 amount) external track {
        amount = bound(amount, 0, 10_000e6);
        pinto.mint(vault, amount);
        if (amount == 0) vm.expectRevert(VaultBase.NothingPending.selector);
        VaultBase(vault).seed();
        if (amount == 0) return;
        okSeed++;
        pintoSeeded += amount;
        pintoDeposited += amount;
    }

    // ---- helpers ----

    /// The swap itself, as `who` through the router; external so `sell` can catch the trader's own shortfall.
    function swapAs(address who, bool isBuy, int256 amountSpecified, uint256 wethSpecified) external {
        require(msg.sender == address(this), "self");
        _swap(who, isBuy, amountSpecified, wethSpecified);
    }

    /// Swaps and checks the hook's fee: the same share of the trader's WETH leg in all four cases (R8), within 1 wei
    /// of rounding, at the toll the clock gives now. `wethSpecified` is the WETH amount when WETH is the specified
    /// side (exact-in buy, exact-out sell), else 0.
    function _swap(address who, bool isBuy, int256 amountSpecified, uint256 wethSpecified) internal {
        uint256 bps = FeeMath.tollBps(block.timestamp, launchedAt, FEE_BPS); // R26: our clock, our fee
        uint256 v0 = weth.balanceOf(vault);
        int256 w0 = int256(weth.balanceOf(who));
        vm.prank(who);
        router.swap(key, isBuy != coinIs0, amountSpecified);
        uint256 fee = weth.balanceOf(vault) - v0;
        int256 dw = int256(weth.balanceOf(who)) - w0;
        int256 legSigned = isBuy ? -dw : dw;
        assertGe(legSigned, 0, "the trader's WETH moved the right way");
        uint256 leg = uint256(legSigned);
        if (wethSpecified != 0) assertEq(leg, wethSpecified, "WETH-specified swaps fill exactly");
        assertApproxEqAbs(fee, leg * bps / 1e4, 1, "fee = bps of the trader's WETH leg");
        feesIn += fee;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        coin.approve(spender, amount);
    }

    function _assertAllowanceSpent(address a, uint256 before, uint256 spent) internal view {
        uint256 left = coin.allowance(a, address(router));
        if (before == type(uint256).max) assertEq(left, type(uint256).max, "max allowance never falls");
        else assertEq(left, before - spent, "finite allowance falls by what was pulled");
    }

    /// Keeper tips are WETH (convert) or Pinto (buyback), never both in one call, so one sum measures either.
    function _keeper() internal view returns (uint256) {
        return weth.balanceOf(KEEPER) + pinto.balanceOf(KEEPER);
    }

    function _snap() internal view returns (Snap memory) {
        return Snap(
            weth.balanceOf(SAFE),
            weth.balanceOf(CREATOR),
            _keeper(),
            weth.balanceOf(SWAP_ROUTER02),
            pinto.balanceOf(CBETH_WELL)
        );
    }

    /// Books a split of `fresh` from the ghosts alone (R26) and checks the Safe and the creator got their shares.
    function _noteSplit(Snap memory b, uint256 fresh) internal {
        (uint256 platform, uint256 creator, uint256 share) = FeeMath.split(fresh, CREATOR_BPS);
        uint256 sp = weth.balanceOf(SAFE) - b.safe;
        uint256 cp = weth.balanceOf(CREATOR) - b.creator;
        assertEq(sp, platform, "Safe gets PLATFORM_BPS of the fresh fee");
        assertEq(cp, creator, "creator gets creatorBps of the fresh fee");
        safePaid += sp;
        creatorPaid += cp;
        feesSplit += fresh;
        pendingGhost += share;
    }

    /// The cbETH well's spot price (Pinto per cbETH) is within WELL_TOL_BPS of its pump EMA's. A convert moves it
    /// ~1.4%, so the next one waits for a nudgeWell (the EMA catching up) like it would on chain.
    function _wellOnEma() internal view returns (bool) {
        uint256[] memory r = MockWell(CBETH_WELL).getReserves();
        (uint256 spot, uint256 ema) = (r[0] * WELL_CB, WELL_PINTO * r[1]);
        return (spot > ema ? spot - ema : ema - spot) * 1e4 <= ema * WELL_TOL_BPS;
    }

    /// No swap for a whole EMA_WINDOW, so the projected EMA (R22) is the current tick.
    function _emaSettled() internal view returns (bool) {
        uint64 ts = hook.coin(id).emaTs;
        return ts != 0 && block.timestamp - ts >= EMA_WINDOW;
    }

    /// Stems below the mock Silo's germinating stem.
    function _finishedStems() internal view returns (uint256 n) {
        int96[] memory st = RedeemVault(vault).stems();
        int96 g = silo.germinatingStem();
        for (uint256 i; i < st.length; i++) {
            if (st[i] < g) n++;
        }
    }

    /// The WETH in the coin's pool, from the one locked position: the range between the start tick and the price.
    function _poolWeth() internal view returns (uint256) {
        (uint160 sp,,,) = manager.getSlot0(id);
        uint160 s0 = TickMath.getSqrtPriceAtTick(startTick);
        if (coinIs0) return sp > s0 ? SqrtPriceMath.getAmount1Delta(s0, sp, lockedLiquidity, false) : 0;
        return sp < s0 ? SqrtPriceMath.getAmount0Delta(sp, s0, lockedLiquidity, false) : 0;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function extraCoinCount() external view returns (uint256) {
        return extraCoins.length;
    }
}

/// @dev The launcher as the unit tests build it: real PoolManager, the hook at its flag address, the real factory,
///      the Pinto side mocked at the Constants addresses (R2), the coin forced onto one side of WETH (nonce bump).
abstract contract LauncherInvariantBase is Test {
    using StateLibrary for IPoolManager;

    MockWETH internal weth = MockWETH(WETH);
    MockPinto internal pinto = MockPinto(PINTO);
    MockSiloWithConvert internal silo = MockSiloWithConvert(PINTO_DIAMOND);
    IPoolManager internal manager;
    LauncherFactory internal factory;
    LauncherHook internal hook;
    LaunchToken internal coin;
    address internal vault;
    PoolId internal id;
    RouteHarness internal guard;

    function _coinIsToken0() internal pure virtual returns (bool);
    function _mode() internal pure virtual returns (LauncherFactory.Mode);

    function setUp() public virtual {
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);
        vm.etch(PINTO_DIAMOND, address(new MockSiloWithConvert()).code);

        // The unit tests' market: 690k Pinto / 6.5 cbETH, spot = EMA, router at the TWAP both ways. The well and the
        // router hold far more than their reserves, so a long run never drains them.
        MockWell(CBETH_WELL).setReserves(WELL_PINTO, WELL_CB);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, WELL_PINTO, WELL_CB);
        pinto.mint(CBETH_WELL, 100 * WELL_PINTO);
        MockCbEth(CBETH).mint(CBETH_WELL, 100 * WELL_CB);
        MockV3Pool(V3_WETH_CBETH_POOL).setTick(1345);
        guard = new RouteHarness();
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, guard.cbEthForWeth(1 ether));
        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, guard.wethForCbEth(1 ether));
        MockCbEth(CBETH).mint(SWAP_ROUTER02, 10_000 ether);
        weth.mint(SWAP_ROUTER02, 10_000 ether);
        silo.setNextStem(1);

        manager = new PoolManager(address(this));
        factory = new LauncherFactory(manager, LauncherHook(HOOK), SAFE, address(0xC011EC7));
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(factory), WETH), HOOK);
        hook = LauncherHook(HOOK);

        _forceSide();
        vm.deal(LAUNCHER, 1 ether + LAUNCH_FEE);
        vm.prank(LAUNCHER);
        (address c, address v, PoolId i) = factory.launch{value: 1 ether + LAUNCH_FEE}(
            LauncherFactory.Params({
                name: "Coin",
                symbol: "COIN",
                imageURI: "",
                metadataURI: "",
                mode: _mode(),
                feeBps: FEE_BPS,
                creatorBps: CREATOR_BPS,
                creatorPayout: CREATOR
            })
        );
        (coin, vault, id) = (LaunchToken(c), v, i);
        assertEq(address(coin) < WETH, _coinIsToken0(), "sort order forced");
        weth.mint(address(manager), 1_000 ether); // R9: the beforeSwap fee take is paid from the manager's float
    }

    /// Bumps the factory's nonce until its next CREATE (the coin) lands on this contract's side of WETH.
    function _forceSide() internal {
        uint64 n0 = vm.getNonce(address(factory));
        for (uint64 n = n0;; n++) {
            if ((vm.computeCreateAddress(address(factory), n) < WETH) == _coinIsToken0()) {
                if (n != n0) vm.setNonce(address(factory), n);
                return;
            }
        }
    }
}

/// @dev The invariants every mode keeps. Run with `[invariant]` in foundry.toml (fail_on_revert: an unexpected
///      revert or a failed check inside a handler is a failure).
abstract contract LauncherInvariantChecks is LauncherInvariantBase {
    LauncherHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LauncherHandler(factory, coin, vault, _mode() == LauncherFactory.Mode.Redeem, block.timestamp);
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _selectors()}));
    }

    function _modeSelectors() internal pure virtual returns (bytes4[] memory);

    function _selectors() internal pure returns (bytes4[] memory s) {
        bytes4[] memory m = _modeSelectors();
        s = new bytes4[](13 + m.length);
        s[0] = LauncherHandler.buy.selector;
        s[1] = LauncherHandler.sell.selector;
        s[2] = LauncherHandler.burn.selector;
        s[3] = LauncherHandler.split.selector;
        s[4] = LauncherHandler.convert.selector;
        s[5] = LauncherHandler.warp.selector;
        s[6] = LauncherHandler.newSeason.selector;
        s[7] = LauncherHandler.togglePeg.selector;
        s[8] = LauncherHandler.nudgeWell.selector;
        s[9] = LauncherHandler.launch.selector;
        s[10] = LauncherHandler.stray.selector;
        s[11] = LauncherHandler.buy.selector; // trades are the common case: weight buys double
        s[12] = LauncherHandler.seed.selector;
        for (uint256 i; i < m.length; i++) {
            s[13 + i] = m[i];
        }
    }

    function _checkAll() internal view {
        invariant_supply_only_falls();
        invariant_vault_weth_accounted();
        invariant_hook_holds_nothing();
        invariant_factory_holds_nothing();
        invariant_liquidity_locked();
    }

    function invariant_supply_only_falls() public view {
        uint256 supply = coin.totalSupply();
        assertLe(supply, handler.prevSupply(), "supply rose");
        assertLe(supply, SUPPLY);
        // Every coin is with someone this harness knows: the pool, a trader, the creator. Nobody else holds any.
        uint256 held = coin.balanceOf(address(manager)) + coin.balanceOf(CREATOR);
        for (uint256 i; i < 3; i++) {
            held += coin.balanceOf(handler.actor(i));
        }
        assertEq(held, supply, "coins conserved");
    }

    /// R5: every wei the hook sent the vault is paid out, converted, waiting, or unsplit.
    function invariant_vault_weth_accounted() public view {
        uint256 bal = weth.balanceOf(vault);
        uint256 pending = VaultBase(vault).pendingPintoWeth();
        assertEq(pending, handler.pendingGhost(), "pendingPintoWeth matches the ghost (R26)");
        assertEq(bal - pending, handler.feesIn() - handler.feesSplit(), "unsplit = fees in - fees split");
        assertEq(
            handler.feesIn(),
            handler.safePaid() + handler.creatorPaid() + handler.tipsPaid() + handler.wethConverted() + pending
                + (bal - pending),
            "fees in == safe + creator + tips + converted + pending + unsplit"
        );
        assertEq(pinto.balanceOf(vault), 0, "the vault keeps no loose Pinto");
        assertEq(coin.balanceOf(vault), 0, "the vault keeps no coins");
    }

    function invariant_hook_holds_nothing() public view {
        assertEq(weth.balanceOf(HOOK), 0, "WETH");
        assertEq(coin.balanceOf(HOOK), 0, "coin");
        assertEq(HOOK.balance, 0, "ETH");
        assertEq(manager.balanceOf(HOOK, uint160(WETH)), 0, "WETH claims");
        assertEq(manager.balanceOf(HOOK, uint160(address(coin))), 0, "coin claims");
    }

    /// R24: the factory keeps no coin of any launch, and no WETH or ETH beyond what strangers sent it.
    function invariant_factory_holds_nothing() public view {
        assertEq(coin.balanceOf(address(factory)), 0, "main coin");
        for (uint256 i; i < handler.extraCoinCount(); i++) {
            assertEq(LaunchToken(handler.extraCoins(i)).balanceOf(address(factory)), 0, "launched coin");
        }
        assertEq(weth.balanceOf(address(factory)), handler.strayWeth(), "WETH");
        assertEq(address(factory).balance, handler.strayEth(), "ETH");
    }

    /// The whole supply's position never loses liquidity.
    function invariant_liquidity_locked() public view {
        (int24 lo, int24 hi) = _coinIsToken0()
            ? (handler.startTick(), TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), handler.startTick());
        bytes32 pos = Position.calculatePositionKey(address(factory), lo, hi, 0);
        assertEq(StateLibrary.getPositionLiquidity(manager, id, pos), handler.lockedLiquidity());
    }
}

abstract contract LauncherInvariantRedeem is LauncherInvariantChecks {
    function _mode() internal pure override returns (LauncherFactory.Mode) {
        return LauncherFactory.Mode.Redeem;
    }

    function _modeSelectors() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = LauncherHandler.redeem.selector;
        s[1] = LauncherHandler.claim.selector;
        s[2] = LauncherHandler.merge.selector;
    }

    /// R6: the Silo holds exactly the tally, stem by stem, and the tally is what went in less what came out.
    function invariant_redeem_solvent() public view {
        RedeemVault v = RedeemVault(vault);
        int96[] memory s = v.stems();
        uint256 sum;
        for (uint256 i; i < s.length; i++) {
            assertEq(silo.deposits(vault, s[i]), v.stemAmount(s[i]), "stem tally");
            sum += silo.deposits(vault, s[i]);
        }
        assertEq(sum, v.siloPinto(), "the Silo's deposits on the vault's stems sum to siloPinto");
        assertEq(silo.held(vault), v.siloPinto(), "and the vault has no deposit elsewhere");
        uint256 inflow = handler.pintoDeposited() + handler.pintoPlanted();
        assertLe(handler.pintoRedeemed(), inflow, "redeemed <= deposited + planted");
        assertEq(v.siloPinto(), inflow - handler.pintoRedeemed(), "siloPinto = in - out");
    }

    /// Drives the handler down every Redeem success path (a scripted run, not fuzzed) and checks the counters and the
    /// invariants: buy, four converts across three seasons (the fourth auto-merges), claim, redeem, a direct merge.
    function test_handler_reaches_every_path() public {
        handler.buy(0, 20 ether, false);
        for (uint256 i; i < 4; i++) {
            handler.nudgeWell(0);
            handler.convert();
            handler.newSeason();
        }
        handler.claim(100e6);
        handler.seed(500e6);
        handler.redeem(0, coin.balanceOf(handler.actor(0)) / 2, false);
        handler.newSeason();
        handler.newSeason();
        handler.merge();
        assertEq(handler.okConvert(), 4, "converts");
        assertGe(handler.okAutoMerge(), 1, "auto-merge");
        assertEq(handler.okClaim(), 1, "claim");
        assertEq(handler.okRedeem(), 1, "redeem");
        assertEq(handler.okSeed(), 1, "seed");
        assertEq(handler.okMerge(), 1, "merge");
        _checkAll();
        invariant_redeem_solvent();
        invariant_backing_never_falls();
    }

    /// siloPinto / totalSupply never falls across a handler call (cross-multiplied, exact).
    function invariant_backing_never_falls() public view {
        assertGe(
            VaultBase(vault).siloPinto() * handler.prevSupply(),
            handler.prevSilo() * coin.totalSupply(),
            "backing per coin fell"
        );
    }
}

abstract contract LauncherInvariantBurn is LauncherInvariantChecks {
    function _mode() internal pure override returns (LauncherFactory.Mode) {
        return LauncherFactory.Mode.Burn;
    }

    function _modeSelectors() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = LauncherHandler.buyback.selector;
    }

    /// Drives the handler down the Burn success path (scripted): buy, a quiet EMA window, convert, plant + buyback.
    function test_handler_reaches_every_path() public {
        handler.buy(0, 1 ether, false);
        handler.warp(2 hours);
        handler.convert();
        handler.seed(500e6);
        handler.buyback(100e6, 100e6);
        assertEq(handler.okConvert(), 1, "convert");
        assertEq(handler.okSeed(), 1, "seed");
        assertEq(handler.okBuyback(), 1, "buyback");
        assertEq(handler.pintoBoughtBack(), 100e6, "the whole planted batch spent");
        _checkAll();
        invariant_burn_principal_never_falls();
    }

    /// Principal (siloPinto − yieldPinto) never falls, is exactly the converted Pinto, and the Silo holds it all.
    function invariant_burn_principal_never_falls() public view {
        BurnVault v = BurnVault(vault);
        uint256 principal = v.siloPinto() - v.yieldPinto();
        assertGe(principal, handler.prevPrincipal(), "principal fell");
        assertEq(principal, handler.pintoDeposited(), "principal is the converted + seeded Pinto");
        assertEq(v.yieldPinto(), handler.pintoPlanted() - handler.pintoBoughtBack(), "yield = planted - spent");
        assertEq(silo.held(vault), v.siloPinto(), "the Silo holds the tally");
    }
}

contract LauncherInvariantRedeemCoin0 is LauncherInvariantRedeem {
    function _coinIsToken0() internal pure override returns (bool) {
        return true;
    }
}

contract LauncherInvariantRedeemCoin1 is LauncherInvariantRedeem {
    function _coinIsToken0() internal pure override returns (bool) {
        return false;
    }
}

contract LauncherInvariantBurnCoin0 is LauncherInvariantBurn {
    function _coinIsToken0() internal pure override returns (bool) {
        return true;
    }
}

contract LauncherInvariantBurnCoin1 is LauncherInvariantBurn {
    function _coinIsToken0() internal pure override returns (bool) {
        return false;
    }
}

/// @dev Round trips against a freshly launched Redeem coin (10 WETH FDV start, 1 WETH creator first buy).
abstract contract LauncherInvariantFuzz is LauncherInvariantBase {
    using StateLibrary for IPoolManager;

    address internal constant TRADER = address(0x7AADE);
    Actor internal router;
    PoolKey internal key;

    function _mode() internal pure override returns (LauncherFactory.Mode) {
        return LauncherFactory.Mode.Redeem;
    }

    function setUp() public override {
        super.setUp();
        router = new Actor(manager);
        key = PoolKey(
            Currency.wrap(_coinIsToken0() ? address(coin) : WETH),
            Currency.wrap(_coinIsToken0() ? WETH : address(coin)),
            LP_FEE,
            TICK_SPACING,
            IHooks(HOOK)
        );
        weth.mint(TRADER, 1_000_000 ether);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        coin.approve(vault, type(uint256).max);
        vm.stopPrank();
    }

    /// Buy (exact-in WETH or exact-out coins), then sell every coin bought (exact-in) or try to sell for exactly the
    /// WETH spent (exact-out): the trader never ends with more WETH, in or after the toll window.
    function testFuzz_buy_then_sell_never_profits(uint256 amount, uint256 waitSecs, bool exactOutBuy, bool exactOutSell)
        public
    {
        vm.warp(block.timestamp + bound(waitSecs, 0, 20 minutes));
        uint256 w0 = weth.balanceOf(TRADER);
        if (exactOutBuy) _trade(true, int256(bound(amount, 1, SUPPLY / 10)));
        else _trade(true, -int256(bound(amount, 1, 50 ether)));
        uint256 coins = coin.balanceOf(TRADER);
        uint256 spent = w0 - weth.balanceOf(TRADER);

        if (exactOutSell && spent != 0) {
            try this.trade(false, int256(spent)) {}
            catch (bytes memory e) {
                assertEq(bytes4(e), LaunchToken.Balance.selector, "only short of coins");
            }
        } else if (coins != 0) {
            _trade(false, -int256(coins));
        }
        assertLe(weth.balanceOf(TRADER), w0, "round trip profited");
        if (spent >= 1e4) assertLt(weth.balanceOf(TRADER), w0, "the fee is paid");
    }

    /// While the pool prices the coin above its Silo backing, buying and redeeming at once returns less Pinto value
    /// (at the cbETH well's and the v3 pool's mid prices, no fees) than the WETH paid.
    function testFuzz_buy_redeem_round_trip_never_profits(uint256 wethIn, uint256 backing, uint256 waitSecs) public {
        silo.setPlant(bound(backing, 1e6, 2_000_000e6), 1);
        RedeemVault(vault).claim();
        vm.warp(block.timestamp + bound(waitSecs, 0, 20 minutes));
        uint256 supply = coin.totalSupply();
        uint256 silo0 = VaultBase(vault).siloPinto();
        // Pool price vs backing, both in WETH per coin, as X96 ratios.
        (uint160 sp,,,) = manager.getSlot0(id);
        uint256 p = uint256(sp) * sp >> 96; // token1 per token0, X96
        uint256 poolX96 = _coinIsToken0() ? p : (uint256(1) << 192) / p;
        uint256 backX96 = (_pintoToWeth(silo0) << 96) / supply;
        vm.assume(poolX96 > backX96);

        uint256 w0 = weth.balanceOf(TRADER);
        _trade(true, -int256(bound(wethIn, 1e6, 50 ether)));
        uint256 paid = w0 - weth.balanceOf(TRADER);
        uint256 coins = coin.balanceOf(TRADER);
        vm.prank(TRADER);
        try RedeemVault(vault).redeem(coins, 0, TRADER) returns (uint256 out) {
            assertLt(_pintoToWeth(out), paid, "redeem round trip profited");
        } catch (bytes memory e) {
            assertEq(bytes4(e), VaultBase.ZeroOut.selector);
        }
    }

    function trade(bool isBuy, int256 amountSpecified) external {
        require(msg.sender == address(this));
        _trade(isBuy, amountSpecified);
    }

    function _trade(bool isBuy, int256 amountSpecified) internal {
        vm.prank(TRADER);
        router.swap(key, isBuy != _coinIsToken0(), amountSpecified);
    }

    /// Pinto -> cbETH at the well's spot (= its EMA here), cbETH -> WETH at the v3 TWAP; no fees, no impact.
    function _pintoToWeth(uint256 pintoAmount) internal view returns (uint256) {
        return guard.wethForCbEth(pintoAmount * WELL_CB / WELL_PINTO);
    }
}

contract LauncherInvariantFuzzCoin0 is LauncherInvariantFuzz {
    function _coinIsToken0() internal pure override returns (bool) {
        return true;
    }
}

contract LauncherInvariantFuzzCoin1 is LauncherInvariantFuzz {
    function _coinIsToken0() internal pure override returns (bool) {
        return false;
    }
}
