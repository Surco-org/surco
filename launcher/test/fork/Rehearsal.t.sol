// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPintoSilo} from "chirp/interfaces/IPintoSilo.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {LauncherFactory} from "../../src/LauncherFactory.sol";
import {LauncherHook} from "../../src/LauncherHook.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {VaultBase, IPintoPeg} from "../../src/VaultBase.sol";
import {RedeemVault} from "../../src/RedeemVault.sol";
import {BurnVault} from "../../src/BurnVault.sol";
import {IUniversalRouter, IPermit2, PERMIT2, IV4Quoter, RouterGateBase} from "./RouterGate.t.sol";
import {IPintoViews} from "./LambdaMerge.t.sol";
import {SlippageOut} from "./PintoRoute.t.sol";
import {IWell} from "../../src/interfaces/IWell.sol";
import {
    WETH,
    PINTO,
    PINTO_DIAMOND,
    UNIVERSAL_ROUTER,
    V4_QUOTER,
    TICK_SPACING,
    LP_FEE,
    TOLL_WINDOW,
    EMA_WINDOW,
    PLATFORM_BPS,
    TIP_BPS,
    REDEEM_FEE_BPS,
    MERGE_ABOVE_STEMS,
    CBETH,
    CBETH_WELL,
    WELL_TOL_BPS,
    WELL_FEE_BPS,
    MAX_CONVERT_WETH,
    LAUNCH_FEE
} from "../../src/Constants.sol";

/// Pinto's deposit transfer (SiloFacet), used only to stand in for planted yield (see the shared-stem tests).
interface ISiloTransfer {
    function transferDeposit(address sender, address recipient, address token, int96 stem, uint256 amount)
        external
        returns (uint256 bdv);
}

/// @dev The whole launcher on a Base fork: the hook and factory deployed by script/Deploy.s.sol (mined CREATE2 salt),
///      one Redeem and one Burn coin launched with a 1 ETH creator first buy, traded through the real Universal
///      Router, their fees split and converted into the real Pinto Silo. Both sort orders (two contracts below).
///      Run with -vv to see the gas lines.
abstract contract RehearsalBase is Test {
    /// Base, 2026-11-20 (the block every fork test pins). Pinto is below peg here.
    uint256 internal constant FORK_BLOCK = 60_050_000;

    address internal constant SAFE = address(0x5AFE); // the platform Safe is a plain test address here
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0x7AADE);
    address internal constant KEEPER = address(0x4EE9E4);
    address internal constant ATTACKER = address(0xBAD);
    uint16 internal constant FEE_BPS = 100;
    uint16 internal constant CREATOR_BPS = 1000;
    uint256 internal constant FIRST_BUY = 1 ether;

    // Universal Router Commands.sol / v4-periphery Actions.sol (as RouterGate.t.sol).
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    IPintoSilo internal constant SILO = IPintoSilo(PINTO_DIAMOND);

    LauncherHook internal hook;
    LauncherFactory internal factory;
    LaunchToken internal rCoin;
    RedeemVault internal rVault;
    PoolKey internal rKey;
    LaunchToken internal bCoin;
    BurnVault internal bVault;
    PoolKey internal bKey;
    uint256 internal launchGas;
    uint256 internal swapGas;

    function _coinIsToken0() internal pure virtual returns (bool);

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        (hook, factory,,) = new Deploy().deploy(SAFE);
        assertEq(hook.factory(), address(factory), "R1");

        vm.deal(CREATOR, 10 ether);
        address vault;
        (rCoin, vault, rKey) = _launch(LauncherFactory.Mode.Redeem);
        rVault = RedeemVault(vault);
        assertEq(rVault.factory(), address(factory.redeemDeployer()), "R23");
        (bCoin, vault, bKey) = _launch(LauncherFactory.Mode.Burn);
        bVault = BurnVault(vault);
        assertEq(bVault.factory(), address(factory.burnDeployer()), "R23");
        (,,,, IHooks hooks) = bVault.poolKey();
        assertEq(address(hooks), address(hook), "Burn pool key set");

        vm.warp(block.timestamp + TOLL_WINDOW); // past the sniper toll: every trade below pays FEE_BPS

        deal(WETH, TRADER, 100 ether);
        vm.startPrank(TRADER);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        for (uint256 i; i < 2; i++) {
            address c = i == 0 ? address(rCoin) : address(bCoin);
            IERC20(c).approve(PERMIT2, type(uint256).max);
            IPermit2(PERMIT2).approve(c, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        }
        vm.stopPrank();
    }

    // ---- the rehearsal ----

    /// Pre-launch gate 3: the sniper toll through the real Universal Router, on the real hook. At launch, mid-window,
    /// the window's last second and after it, every swap shape (exact in/out, buy/sell) quotes exactly what it fills
    /// and pays the toll's bps of the trader's WETH leg. setUp warped past the window; the toll is read by timestamp
    /// against launchedAt, so warping back to it is the same clock a sniper meets (no swap ran after the first buy).
    function test_sniper_toll_through_router() public {
        uint64 t0 = hook.coin(bKey.toId()).launchedAt;
        assertGt(t0, 0, "clock started at launch");
        uint256[4] memory dt = [uint256(0), TOLL_WINDOW / 2, TOLL_WINDOW - 1, TOLL_WINDOW];
        uint256[4] memory want = [uint256(8000), 4050, 114, FEE_BPS]; // 8000 - 7900 * dt / 600, floored
        for (uint256 i; i < 4; i++) {
            vm.warp(t0 + dt[i]);
            (, uint256 coins) = _tradeAt(bKey, true, true, 0.1 ether, want[i]); // at 80% only ~0.02 ETH of coins
            _tradeAt(bKey, false, true, uint128(coins / 2), want[i]);
            _tradeAt(bKey, true, false, uint128(coins / 4), want[i]);
            _tradeAt(bKey, false, false, 0.001 ether, want[i]);
        }
    }

    function test_launch() public {
        emit log_named_uint("gas, launch (1 ETH first buy)", launchGas);
        for (uint256 i; i < 2; i++) {
            (LaunchToken c, address v, PoolKey memory k) = i == 0
                ? (rCoin, address(rVault), rKey)
                : (bCoin, address(bVault), bKey);
            LauncherHook.Coin memory info = hook.coin(k.toId());
            assertEq(info.vault, v);
            assertEq(info.coinIsToken0, _coinIsToken0(), "sort order");
            assertGt(info.emaTs, 0, "first buy seeded the EMA");
            assertGt(c.balanceOf(CREATOR), 0, "creator got the first buy");
            assertEq(IERC20(WETH).balanceOf(v), FIRST_BUY * FEE_BPS / 1e4, "first buy's fee, plain");
            assertEq(c.balanceOf(address(factory)), 0);
        }
    }

    /// All four trade shapes through the real Universal Router on both coins: the fee lands in the vault in WETH,
    /// equals FEE_BPS of the trader's WETH leg, and V4Quoter quotes exactly what the swap does.
    function test_ur_trades() public {
        for (uint256 i; i < 2; i++) {
            PoolKey memory k = i == 0 ? rKey : bKey;
            _trade(k, true, true, 1 ether);
            if (i == 0) emit log_named_uint("gas, UR exact-in buy (1 ETH)", swapGas);
            (, uint256 coins) = _trade(k, true, false, 1e24);
            _trade(k, false, true, uint128(coins));
            _trade(k, false, false, 0.5 ether);
        }
    }

    function test_split_convert_redeem() public {
        _volume(rKey);
        _splitPaysSafeAndCreator(rVault);
        uint256 batch = rVault.pendingPintoWeth();

        uint256 g = gasleft();
        vm.prank(KEEPER);
        rVault.convert();
        emit log_named_uint("gas, convert", g - gasleft());
        assertEq(IERC20(WETH).balanceOf(KEEPER), batch * TIP_BPS / 1e4, "keeper tip");
        assertEq(rVault.pendingPintoWeth(), 0);
        assertGt(rVault.siloPinto(), 0, "Pinto in the Silo");
        assertEq(IERC20(PINTO).balanceOf(address(rVault)), 0, "none held loose");
        _assertRedeemBooks();

        (, uint256 coins) = _trade(rKey, true, true, 0.5 ether);
        uint256 out = _redeem(coins);
        assertEq(IERC20(PINTO).balanceOf(TRADER), out);
        _assertRedeemBooks();
    }

    /// Five converts in five seasons (auto-merge runs once there are more than three stems), then two more seasons
    /// so every stem has finished germinating, then merge() leaves one stem. The books match the Silo throughout.
    function test_seasons_convert_merge() public {
        for (uint256 i; i < 5; i++) {
            _volume(rKey);
            rVault.convert();
            assertLe(rVault.stems().length, MERGE_ABOVE_STEMS, "auto-merge ran on the real Diamond");
            _assertRedeemBooks();
            _sunrise();
        }
        _sunrise();
        assertGt(rVault.stems().length, 1);
        uint256 total = rVault.siloPinto();
        rVault.merge();
        int96[] memory s = rVault.stems();
        assertEq(s.length, 1, "one stem");
        assertEq(rVault.stemAmount(s[0]), total);
        _assertRedeemBooks();

        (, uint256 coins) = _trade(rKey, true, true, 0.5 ether);
        _redeem(coins);
        _assertRedeemBooks();
    }

    /// R28: someone swaps cbETH into the well first, moving its spot price 1% against the batch. convert() reverts
    /// (the pump's EMA did not move) and the WETH waits.
    function test_convert_reverts_on_1pct_well_push() public {
        _fundBatch();
        uint256 pending = rVault.pendingPintoWeth();
        uint256 before = IWell(CBETH_WELL).getSwapOut(CBETH, PINTO, 1e16);
        uint256[] memory r = IWell(CBETH_WELL).getReserves();
        _wellSwap(CBETH, PINTO, r[1] * 51 / 1e4); // (1 / 1.0051)^2 = 0.9899
        uint256 spot = IWell(CBETH_WELL).getSwapOut(CBETH, PINTO, 1e16);
        assertLe(spot * 1e4, before * 9900, "spot moved >= 1%");
        assertGe(spot * 1e4, before * 9890, "and not much more");

        vm.expectPartialRevert(SlippageOut.selector, CBETH_WELL);
        rVault.convert();
        assertEq(rVault.pendingPintoWeth(), pending, "WETH waits");
    }

    /// R28: the final review's sandwich, re-run. An attacker swaps cbETH into the well before convert() and sells the
    /// Pinto back after. A convert that still goes through is short of an unattacked one by at most the well leg's
    /// slack (WELL_TOL_BPS + WELL_FEE_BPS while PI-17 is not live). Logs shortfall and attacker P&L with -vv.
    function test_convert_sandwich_bounded() public {
        _fundBatch();
        uint256 snap = vm.snapshotState();
        rVault.convert();
        uint256 clean = rVault.siloPinto();
        // The review's three pushes, plus 0.024 cbETH: about the largest that still converts at this block.
        uint256[4] memory pushes = [uint256(0.02 ether), 0.024 ether, 0.06 ether, 0.1 ether];
        for (uint256 i; i < 4; i++) {
            vm.revertToState(snap);
            uint256 pintoGot = _wellSwap(CBETH, PINTO, pushes[i]);
            emit log_named_decimal_uint("push, cbETH", pushes[i], 18);
            try rVault.convert() {
                uint256 shortfall = (clean - rVault.siloPinto()) * 1e6 / clean;
                emit log_named_decimal_uint("  converted; vault short of unattacked, bps", shortfall, 2);
                assertLe(shortfall, (WELL_TOL_BPS + WELL_FEE_BPS + 1) * 100, "shortfall within the well's slack");
            } catch (bytes memory e) {
                assertEq(bytes4(e), SlippageOut.selector, "refused by the well leg");
                emit log("  convert reverted");
            }
            int256 pnl = int256(_wellSwap(PINTO, CBETH, pintoGot)) - int256(pushes[i]);
            emit log_named_decimal_int("  attacker P&L, cbETH", pnl, 18);
        }
    }

    /// R28 cost: a full batch moves the well's price ~1.4%, past WELL_TOL_BPS, so a second full convert (any vault)
    /// against the same EMA reverts until the pump catches up. Logs how long that takes with no other well trade.
    function test_back_to_back_converts_wait_for_ema() public {
        _fundBatch();
        rVault.convert();
        deal(WETH, address(bVault), IERC20(WETH).balanceOf(address(bVault)) + 0.1 ether);
        bVault.split();

        vm.expectPartialRevert(SlippageOut.selector, CBETH_WELL);
        bVault.convert();

        uint256 waited;
        while (true) {
            vm.warp(block.timestamp + 30);
            vm.roll(block.number + 150);
            waited += 30;
            try bVault.convert() {
                break;
            } catch {}
            assertLt(waited, 1 hours, "EMA never caught up");
        }
        emit log_named_uint("seconds until the next full convert passes", waited);
    }

    /// Carried from Task 8: the REAL plant() through each vault, at peg (only the diamond's abovePeg() is mocked).
    /// Pinto is below peg at FORK_BLOCK, so nothing was minted to the Silo and plant() earns 0.
    function test_real_plant_zero_is_clean() public {
        _volume(rKey);
        rVault.convert();
        _volume(bKey);
        bVault.convert();
        _sunrise();
        _mockAtPeg();

        int96[] memory stemsBefore = rVault.stems();
        uint256 rSilo = rVault.siloPinto();
        rVault.claim();
        assertEq(rVault.siloPinto(), rSilo, "claim booked nothing");
        assertEq(rVault.stems().length, stemsBefore.length);
        _assertRedeemBooks();

        uint256 bSilo = bVault.siloPinto();
        vm.expectRevert(VaultBase.NothingPending.selector);
        bVault.buyback(1_000e6);
        assertEq(bVault.siloPinto(), bSilo);
        assertEq(bVault.yieldPinto(), 0);

        // The evidence: the real Silo really returns 0 to the vault.
        vm.prank(address(rVault));
        (uint256 beans,) = SILO.plant();
        assertEq(beans, 0, "real plant earns nothing below peg");
    }

    /// Carried from Task 8: Burn buyback spending yield that sits on the SAME stem as a same-season, still-germinating
    /// convert deposit, against the real Diamond, pool, wells and v3 pool.
    /// Real: convert's deposit, the yield deposit and its transfer to the vault, getDeposit, withdrawDeposit, the
    /// Pinto -> cbETH -> WETH route, the coin pool swap, the burn. Simulated: plant()'s RETURN VALUE (vm.mockCall,
    /// (Y, stem)) and its effect on the Silo, which is stood in for by a real deposit of dealt Pinto on the same stem
    /// moved to the vault with transferDeposit; and the diamond's abovePeg() (mocked true).
    function test_burn_buyback_shared_stem() public {
        _volume(bKey);
        bVault.convert();
        int96 stem = SILO.stemTipForToken(PINTO);
        uint256 principal = bVault.siloPinto();
        assertEq(bVault.stemAmount(stem), principal, "convert deposit on the current stem");
        assertGe(stem, SILO.getGerminatingStem(PINTO), "and germinating");

        uint256 y = 1_000e6;
        _standInYield(address(bVault), stem, y);
        _mockAtPeg();
        vm.warp(block.timestamp + EMA_WINDOW); // the EMA has caught up with the pool (R22)

        uint256 supply = bCoin.totalSupply();
        uint256 g = gasleft();
        vm.prank(KEEPER);
        bVault.buyback(y);
        emit log_named_uint("gas, buyback (1,000 Pinto)", g - gasleft());
        vm.clearMockedCalls();

        assertLt(bCoin.totalSupply(), supply, "coins burned");
        assertEq(bCoin.balanceOf(address(bVault)), 0);
        assertEq(IERC20(PINTO).balanceOf(KEEPER), y * TIP_BPS / 1e4, "keeper tip in Pinto");
        assertEq(IERC20(PINTO).balanceOf(address(bVault)), 0);
        assertEq(IERC20(WETH).balanceOf(address(bVault)), bVault.pendingPintoWeth(), "no WETH left over");
        assertEq(bVault.yieldPinto(), 0);
        assertEq(bVault.yieldAt(stem), 0);
        assertEq(bVault.siloPinto(), principal, "principal untouched");
        assertEq(bVault.stemAmount(stem), principal);
        (uint256 dep,) = SILO.getDeposit(address(bVault), PINTO, stem);
        assertEq(dep, principal, "Silo == books on the shared stem");
    }

    /// Carried from Task 8: Redeem's claim + redeem on a stem shared by a same-season convert deposit and yield.
    /// Real and simulated parts as in test_burn_buyback_shared_stem.
    function test_redeem_shared_stem() public {
        _volume(rKey);
        rVault.convert();
        int96 stem = SILO.stemTipForToken(PINTO);
        uint256 principal = rVault.siloPinto();
        assertEq(rVault.stemAmount(stem), principal);

        uint256 y = 1_000e6;
        _standInYield(address(rVault), stem, y);
        _mockAtPeg();
        rVault.claim();
        vm.clearMockedCalls();
        assertEq(rVault.stems().length, 1, "one shared stem");
        assertEq(rVault.stemAmount(stem), principal + y);
        assertEq(rVault.siloPinto(), principal + y);
        _assertRedeemBooks();

        (, uint256 coins) = _trade(rKey, true, true, 0.5 ether);
        uint256 out = _redeem(coins);
        assertEq(rVault.stemAmount(stem), principal + y - out);
        _assertRedeemBooks();
    }

    /// A real seed on the real Silo: a plain Pinto transfer to each vault, then seed(). Burn: principal, not yield.
    function test_seed_real() public {
        deal(PINTO, address(this), 2_000e6);
        IERC20(PINTO).transfer(address(rVault), 1_000e6);
        uint256 s0 = rVault.siloPinto();
        uint256 g = gasleft();
        rVault.seed();
        emit log_named_uint("gas, seed (1,000 Pinto)", g - gasleft());
        assertEq(rVault.siloPinto() - s0, 1_000e6, "redeem vault booked it");
        assertEq(IERC20(PINTO).balanceOf(address(rVault)), 0, "nothing left loose");

        IERC20(PINTO).transfer(address(bVault), 1_000e6);
        uint256 y0 = bVault.yieldPinto();
        s0 = bVault.siloPinto();
        bVault.seed();
        assertEq(bVault.siloPinto() - s0, 1_000e6, "burn vault booked it");
        assertEq(bVault.yieldPinto(), y0, "seed is not yield");
        assertEq(IERC20(PINTO).balanceOf(address(bVault)), 0, "nothing left loose");
    }

    /// Records how the real Silo treats a 1-raw-unit seed: booked, or a clean revert with the unit still loose.
    function test_seed_dust_real() public {
        deal(PINTO, address(bVault), 1);
        uint256 s0 = bVault.siloPinto();
        try bVault.seed() {
            assertEq(bVault.siloPinto(), s0 + 1, "dust booked");
            emit log_named_string("dust seed", "booked");
        } catch (bytes memory err) {
            assertEq(bVault.siloPinto(), s0, "nothing booked");
            assertEq(IERC20(PINTO).balanceOf(address(bVault)), 1, "the unit waits for more");
            emit log_named_bytes("dust seed reverted", err);
        }
    }

    // ---- helpers ----

    function _launch(LauncherFactory.Mode mode) internal returns (LaunchToken coin, address vault, PoolKey memory key) {
        _forceSide();
        LauncherFactory.Params memory p =
            LauncherFactory.Params("Rehearsal", "RHRSL", "ipfs://rehearsal", "https://surcofi.com/meta.json", mode, FEE_BPS, CREATOR_BPS, CREATOR);
        uint256 g = gasleft();
        vm.prank(CREATOR);
        (address c, address v,) = factory.launch{value: FIRST_BUY + LAUNCH_FEE}(p);
        launchGas = g - gasleft();
        (address a, address b) = c < WETH ? (c, WETH) : (WETH, c);
        return (LaunchToken(c), v, PoolKey(Currency.wrap(a), Currency.wrap(b), LP_FEE, TICK_SPACING, IHooks(address(hook))));
    }

    /// Bumps the factory's CREATE nonce until the next coin lands on this contract's side of WETH.
    function _forceSide() internal {
        uint64 n0 = vm.getNonce(address(factory));
        for (uint64 n = n0;; n++) {
            if ((vm.computeCreateAddress(address(factory), n) < WETH) == _coinIsToken0()) {
                if (n != n0) vm.setNonce(address(factory), n);
                return;
            }
        }
    }

    /// One round trip through the router: buy with 1 ETH, sell it all back.
    /// 0.1 WETH of fees into the Redeem vault, split: 0.07 WETH pending, so convert() takes a full 0.05 batch.
    function _fundBatch() internal {
        deal(WETH, address(rVault), IERC20(WETH).balanceOf(address(rVault)) + 0.1 ether);
        rVault.split();
        assertGe(rVault.pendingPintoWeth(), MAX_CONVERT_WETH);
    }

    /// ATTACKER swaps `amountIn` straight through the cbETH well.
    function _wellSwap(address from, address to, uint256 amountIn) internal returns (uint256 out) {
        deal(from, ATTACKER, amountIn);
        vm.startPrank(ATTACKER);
        IERC20(from).approve(CBETH_WELL, amountIn);
        out = IWell(CBETH_WELL).swapFrom(from, to, amountIn, 0, ATTACKER, block.timestamp);
        vm.stopPrank();
    }

    function _volume(PoolKey memory key) internal {
        (, uint256 coins) = _trade(key, true, true, 1 ether);
        _trade(key, false, true, uint128(coins));
    }

    /// A Universal Router v4 single swap by TRADER. Asserts V4Quoter's quote == the swap and the vault's WETH gain ==
    /// FEE_BPS of the trader's WETH leg (R8, ±1 wei of rounding). Returns the trader's legs.
    function _trade(PoolKey memory key, bool buy, bool exactIn, uint128 amount)
        internal
        returns (uint256 wethLeg, uint256 coinLeg)
    {
        return _tradeAt(key, buy, exactIn, amount, FEE_BPS);
    }

    /// `_trade` with the fee the hook should charge right now (the sniper toll's bps inside the window).
    function _tradeAt(PoolKey memory key, bool buy, bool exactIn, uint128 amount, uint256 bps)
        internal
        returns (uint256 wethLeg, uint256 coinLeg)
    {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == WETH);
        IV4Quoter.QuoteExactSingleParams memory q = IV4Quoter.QuoteExactSingleParams(key, zeroForOne, amount, "");
        uint256 quoted;
        if (exactIn) (quoted,) = IV4Quoter(V4_QUOTER).quoteExactInputSingle(q);
        else (quoted,) = IV4Quoter(V4_QUOTER).quoteExactOutputSingle(q);

        address vault = hook.coin(key.toId()).vault;
        uint256 fee0 = IERC20(WETH).balanceOf(vault);
        (wethLeg, coinLeg) = _execute(key, zeroForOne, buy, exactIn, amount);

        // A buy's WETH leg is paid and a sell's received; exact-in specifies the paid leg, exact-out the received one.
        (uint256 specified, uint256 other) = (exactIn == buy) ? (wethLeg, coinLeg) : (coinLeg, wethLeg);
        assertEq(specified, amount, "specified leg exact");
        assertEq(quoted, other, "quoter == swap");
        assertApproxEqAbs(IERC20(WETH).balanceOf(vault) - fee0, wethLeg * bps / 1e4, 1, "fee = bps of WETH leg");
    }

    /// RouterGate.t.sol's encoding: one V4_SWAP command, then SETTLE_ALL the input and TAKE_ALL the output.
    function _execute(PoolKey memory key, bool zeroForOne, bool buy, bool exactIn, uint128 amount)
        internal
        returns (uint256 wethLeg, uint256 coinLeg)
    {
        address coin = Currency.unwrap(zeroForOne == buy ? key.currency1 : key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = exactIn
            ? abi.encode(RouterGateBase.ExactInputSingleParams(key, zeroForOne, amount, 0, ""))
            : abi.encode(RouterGateBase.ExactOutputSingleParams(key, zeroForOne, amount, type(uint128).max, ""));
        params[1] = abi.encode(buy ? WETH : coin, exactIn ? uint256(amount) : type(uint128).max);
        params[2] = abi.encode(buy ? coin : WETH, exactIn ? 0 : uint256(amount));
        bytes[] memory inputs = new bytes[](1);
        uint8 action = exactIn ? SWAP_EXACT_IN_SINGLE : SWAP_EXACT_OUT_SINGLE;
        inputs[0] = abi.encode(abi.encodePacked(action, SETTLE_ALL, TAKE_ALL), params);

        int256 weth0 = int256(IERC20(WETH).balanceOf(TRADER));
        int256 coin0 = int256(IERC20(coin).balanceOf(TRADER));
        uint256 g = gasleft();
        vm.prank(TRADER);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
        swapGas = g - gasleft();
        int256 dWeth = int256(IERC20(WETH).balanceOf(TRADER)) - weth0;
        int256 dCoin = int256(IERC20(coin).balanceOf(TRADER)) - coin0;
        wethLeg = uint256(dWeth < 0 ? -dWeth : dWeth);
        coinLeg = uint256(dCoin < 0 ? -dCoin : dCoin);
    }

    function _splitPaysSafeAndCreator(VaultBase vault) internal {
        uint256 fresh = IERC20(WETH).balanceOf(address(vault)) - vault.pendingPintoWeth();
        uint256 safe0 = IERC20(WETH).balanceOf(SAFE);
        uint256 creator0 = IERC20(WETH).balanceOf(CREATOR);
        uint256 pending0 = vault.pendingPintoWeth();
        vault.split();
        uint256 platform = fresh * PLATFORM_BPS / 1e4;
        uint256 creator = fresh * CREATOR_BPS / 1e4;
        assertEq(IERC20(WETH).balanceOf(SAFE) - safe0, platform, "Safe paid");
        assertEq(IERC20(WETH).balanceOf(CREATOR) - creator0, creator, "creator paid");
        assertEq(vault.pendingPintoWeth() - pending0, fresh - platform - creator, "rest waits for Pinto");
    }

    /// TRADER redeems `coins` from the Redeem vault; asserts the share and returns the Pinto paid.
    function _redeem(uint256 coins) internal returns (uint256 out) {
        uint256 gross = coins * rVault.siloPinto() / rCoin.totalSupply();
        uint256 expected = gross - (gross * REDEEM_FEE_BPS + 9_999) / 1e4;
        uint256 before = IERC20(PINTO).balanceOf(TRADER);
        vm.startPrank(TRADER);
        rCoin.approve(address(rVault), coins);
        uint256 g = gasleft();
        out = rVault.redeem(coins, expected, TRADER);
        emit log_named_uint("gas, redeem", g - gasleft());
        vm.stopPrank();
        assertEq(out, expected, "the share less REDEEM_FEE_BPS");
        assertEq(IERC20(PINTO).balanceOf(TRADER) - before, out);
    }

    /// The Redeem vault's books against the real Silo, stem by stem.
    function _assertRedeemBooks() internal view {
        int96[] memory s = rVault.stems();
        uint256 sum;
        for (uint256 i; i < s.length; i++) {
            (uint256 dep,) = SILO.getDeposit(address(rVault), PINTO, s[i]);
            assertEq(dep, rVault.stemAmount(s[i]), "getDeposit == stemAmount");
            sum += dep;
        }
        assertEq(sum, rVault.siloPinto(), "sum == siloPinto");
    }

    /// Stands in for plant(): a real deposit of `y` dealt Pinto on `stem` (this season's), moved to `vault` with the
    /// Silo's own transferDeposit, and plant() mocked to return (y, stem) so the vault's real code books it.
    function _standInYield(address vault, int96 stem, uint256 y) internal {
        deal(PINTO, address(this), y);
        IERC20(PINTO).approve(PINTO_DIAMOND, y);
        (,, int96 s) = SILO.deposit(PINTO, y, 0);
        assertEq(s, stem, "same season, same stem");
        ISiloTransfer(PINTO_DIAMOND).transferDeposit(address(this), vault, PINTO, stem, y);
        vm.mockCall(PINTO_DIAMOND, abi.encodeWithSelector(IPintoSilo.plant.selector), abi.encode(y, stem));
    }

    function _mockAtPeg() internal {
        vm.mockCall(PINTO_DIAMOND, abi.encodeWithSelector(IPintoPeg.abovePeg.selector), abi.encode(true));
    }

    /// Next hour boundary, then sunrise() at the keeper's 6M gas (as LambdaMerge.t.sol).
    function _sunrise() internal {
        uint32 before = IPintoViews(PINTO_DIAMOND).season();
        vm.warp((block.timestamp / 3600 + 1) * 3600);
        vm.roll(block.number + 1800);
        IPintoViews(PINTO_DIAMOND).sunrise{gas: 6_000_000}();
        assertEq(IPintoViews(PINTO_DIAMOND).season(), before + 1, "season advanced");
    }
}

contract RehearsalCoinToken0Test is RehearsalBase {
    function _coinIsToken0() internal pure override returns (bool) {
        return true;
    }
}

contract RehearsalCoinToken1Test is RehearsalBase {
    function _coinIsToken0() internal pure override returns (bool) {
        return false;
    }
}
