// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {MockWETH} from "./mocks/LauncherMocks.sol";
import {Actor} from "./LauncherHook.t.sol";
import {LauncherFactory} from "../src/LauncherFactory.sol";
import {RedeemDeployer, BurnDeployer} from "../src/VaultDeployers.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {VaultBase} from "../src/VaultBase.sol";
import {BurnVault} from "../src/BurnVault.sol";
import {WETH, SUPPLY, TICK_SPACING, LP_FEE, START_FDV_WETH, TOLL_START_BPS, LAUNCH_FEE} from "../src/Constants.sol";

/// @dev Every test runs with the coin on both sides of WETH (the two concrete contracts at the bottom). The coin's
///      address comes from the factory's CREATE nonce, so `_forceSide` bumps that nonce until the next coin lands on
///      the wanted side of the real WETH address.
abstract contract LauncherFactoryBase is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK = address(uint160(0x2AEC | (uint256(0xB0B) << 148)));
    address internal constant SAFE = address(0x5AFE);
    address internal constant LAUNCHER = address(0x1A0C4);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0x7AADE);
    uint16 internal constant FEE_BPS = 100;
    uint16 internal constant CREATOR_BPS = 1000;
    /// SUPPLY × 1.0001^tick = 10 WETH at tick −184,216.02 (coin token0); the nearest multiple of 200.
    int24 internal constant START = -184_200;

    address internal constant COLLECTIVE = address(0xC011EC7);

    IPoolManager internal manager;
    LauncherFactory internal factory;
    LauncherHook internal hook;
    MockWETH internal weth = MockWETH(WETH);

    function _coinIsToken0() internal pure virtual returns (bool);

    function setUp() public {
        vm.etch(WETH, address(new MockWETH()).code);
        manager = new PoolManager(address(this));
        factory = new LauncherFactory(manager, LauncherHook(HOOK), SAFE, COLLECTIVE);
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(factory), WETH), HOOK);
        hook = LauncherHook(HOOK);
        vm.deal(LAUNCHER, 100 ether);
    }

    // ---- launch ----

    function test_launch_redeem() public {
        (address coin, address vault, PoolId id) = _launch(LauncherFactory.Mode.Redeem, 0);
        _assertLaunched(coin, vault, id);
    }

    function test_launch_burn() public {
        (address coin, address vault, PoolId id) = _launch(LauncherFactory.Mode.Burn, 0);
        _assertLaunched(coin, vault, id);
        (,,,, IHooks hooks) = BurnVault(vault).poolKey();
        assertEq(address(hooks), HOOK, "Burn vault's pool key set");
        assertEq(PoolId.unwrap(_storedKeyId(BurnVault(vault))), PoolId.unwrap(id), "and it is this pool");
    }

    function test_start_price_matches_fdv() public {
        (,, PoolId id) = _launch(LauncherFactory.Mode.Redeem, 0);
        (uint160 sp, int24 tick,,) = manager.getSlot0(id);
        assertEq(tick, _coinIsToken0() ? START : -START, "start tick");
        assertEq(tick % TICK_SPACING, 0, "on the spacing");
        // The whole SUPPLY priced at the start: within one tick spacing (1.0001^200 - 1 = 2.02%) of 10 WETH.
        uint256 p = FullMath.mulDiv(sp, sp, 1 << 96); // token1 per token0, X96
        uint256 fdv = _coinIsToken0() ? FullMath.mulDiv(SUPPLY, p, 1 << 96) : FullMath.mulDiv(SUPPLY, 1 << 96, p);
        assertApproxEqRel(fdv, START_FDV_WETH, 0.0202e18, "FDV at start");
        assertApproxEqRel(fdv, 10.016e18, 0.0001e18, "nearest spacing: 1e9 x 1.0001^-184200 = 10.016 WETH in both orders");
    }

    function test_first_buy_goes_to_creator() public {
        vm.recordLogs();
        (address coin, address vault, PoolId id) = _launch(LauncherFactory.Mode.Redeem, 1 ether);
        uint256 bought = LaunchToken(coin).balanceOf(CREATOR);
        assertGt(bought, 0, "creator payout got the coins");
        assertEq(LaunchToken(coin).balanceOf(LAUNCHER), 0, "not msg.sender");
        assertEq(weth.balanceOf(vault), 1 ether * uint256(FEE_BPS) / 1e4, "plain fee, not the toll");
        assertLt(weth.balanceOf(vault), 1 ether * TOLL_START_BPS / 1e4);
        // ~0.99 WETH at ~1e-8 WETH per coin, less the price impact against 10 WETH of virtual depth.
        assertApproxEqRel(bought, 0.99e8 * 1e18, 0.12e18, "price at the start");
        assertEq(manager.getLiquidity(id) > 0, true, "the buy moved into the range");

        _assertLaunchedEvent(coin, vault, id, LauncherFactory.Mode.Redeem, 1 ether, bought);
        assertEq(hook.coin(id).emaTs, block.timestamp, "the first buy seeds the EMA");
    }

    function test_launch_no_value_ok() public {
        vm.recordLogs();
        uint256 col0 = weth.balanceOf(COLLECTIVE);
        (address coin, address vault, PoolId id) = _launch(LauncherFactory.Mode.Burn, 0);
        assertEq(LaunchToken(coin).balanceOf(CREATOR), 0);
        assertEq(weth.balanceOf(vault), 0);
        assertEq(weth.balanceOf(COLLECTIVE) - col0, LAUNCH_FEE, "launch fee sent to CollectiveSilo");
        assertEq(hook.coin(id).emaTs, 0, "no swap");
        assertEq(hook.coin(id).launchedAt, block.timestamp);
        _assertLaunchedEvent(coin, vault, id, LauncherFactory.Mode.Burn, 0, 0);
    }

    function test_launch_under_fee_reverts() public {
        LauncherFactory.Params memory p = _params(LauncherFactory.Mode.Redeem);
        vm.expectRevert(LauncherFactory.InsufficientLaunchFee.selector);
        vm.prank(LAUNCHER);
        factory.launch{value: LAUNCH_FEE - 1}(p);
    }

    function test_bad_params_revert() public {
        LauncherFactory.Params memory p = _params(LauncherFactory.Mode.Redeem);
        p.feeBps = 29;
        _expectLaunchRevert(p, LauncherFactory.BadFee.selector);
        p.feeBps = 301;
        _expectLaunchRevert(p, LauncherFactory.BadFee.selector);

        p = _params(LauncherFactory.Mode.Burn);
        p.creatorBps = 2001;
        _expectLaunchRevert(p, LauncherFactory.BadCreatorBps.selector);

        p = _params(LauncherFactory.Mode.Redeem);
        p.creatorPayout = address(0);
        _expectLaunchRevert(p, LauncherFactory.ZeroAddress.selector);
        // The factory as payout would burn the creator's first buy with the dust and keep the creator fees forever.
        p.creatorPayout = address(factory);
        _expectLaunchRevert(p, LauncherFactory.BadPayout.selector);

        p = _params(LauncherFactory.Mode.Redeem);
        p.name = "";
        _expectLaunchRevert(p, LauncherFactory.EmptyName.selector);
        p = _params(LauncherFactory.Mode.Redeem);
        p.symbol = "";
        _expectLaunchRevert(p, LauncherFactory.EmptyName.selector);

        // The bounds themselves are fine.
        p = _params(LauncherFactory.Mode.Redeem);
        p.feeBps = 30;
        p.creatorBps = 2000;
        _forceSide();
        vm.prank(LAUNCHER);
        factory.launch{value: LAUNCH_FEE}(p);
        p.feeBps = 300;
        _forceSide();
        vm.prank(LAUNCHER);
        factory.launch{value: LAUNCH_FEE}(p);
    }

    function test_constructor_zero_safe_reverts() public {
        vm.expectRevert(LauncherFactory.ZeroAddress.selector);
        new LauncherFactory(manager, hook, address(0), COLLECTIVE);
        vm.expectRevert(LauncherFactory.ZeroAddress.selector);
        new LauncherFactory(manager, hook, SAFE, address(0));
    }

    /// The vaults' `factory` is their deployer; only the LauncherFactory can drive either deployer.
    function test_deployers_only_answer_the_factory() public {
        (, address redeemVault,) = _launch(LauncherFactory.Mode.Redeem, 0);
        assertEq(VaultBase(redeemVault).factory(), address(factory.redeemDeployer()));
        (address coin, address vault,) = _launch(LauncherFactory.Mode.Burn, 0);
        assertEq(VaultBase(vault).factory(), address(factory.burnDeployer()));
        RedeemDeployer rd = factory.redeemDeployer();
        BurnDeployer bd = factory.burnDeployer();
        LaunchToken token = LaunchToken(coin);
        vm.expectRevert(RedeemDeployer.OnlyLauncher.selector);
        rd.deploy(token, SAFE, CREATOR, 0);
        vm.expectRevert(BurnDeployer.OnlyLauncher.selector);
        bd.deploy(token, SAFE, CREATOR, 0, manager, hook);
        vm.expectRevert(BurnDeployer.OnlyLauncher.selector);
        bd.setPoolKey(BurnVault(vault), _key(coin));
    }

    function test_factory_keeps_nothing() public {
        for (uint256 i; i < 2; i++) {
            (address coin,,) = _launch(i == 0 ? LauncherFactory.Mode.Redeem : LauncherFactory.Mode.Burn, 3 ether);
            assertEq(LaunchToken(coin).balanceOf(address(factory)), 0, "no coins");
            assertEq(weth.balanceOf(address(factory)), 0, "no WETH");
            assertEq(address(factory).balance, 0, "no ETH");
            // Every coin is in the pool or with the creator; the liquidity-rounding dust was burned.
            assertEq(
                LaunchToken(coin).balanceOf(address(manager)) + LaunchToken(coin).balanceOf(CREATOR),
                LaunchToken(coin).totalSupply()
            );
        }
    }

    /// Stray WETH or ETH sent to the factory cannot brick launches: the check is that a launch leaves behind
    /// nothing it brought in, and the stray balance stays where it was.
    function test_stray_balance_does_not_block_launch() public {
        weth.mint(address(factory), 5);
        vm.deal(address(factory), 7);
        _launch(LauncherFactory.Mode.Redeem, 1 ether);
        assertEq(weth.balanceOf(address(factory)), 5);
        assertEq(address(factory).balance, 7);
    }

    function test_two_launches_independent() public {
        (address coinA, address vaultA, PoolId idA) = _launch(LauncherFactory.Mode.Redeem, 1 ether);
        (address coinB, address vaultB, PoolId idB) = _launch(LauncherFactory.Mode.Burn, 0);
        assertTrue(coinA != coinB && vaultA != vaultB, "fresh contracts");
        assertTrue(PoolId.unwrap(idA) != PoolId.unwrap(idB), "two pools");
        assertEq(hook.coin(idA).vault, vaultA);
        assertEq(hook.coin(idB).vault, vaultB);
        assertEq(address(VaultBase(vaultA).coin()), coinA);
        assertEq(address(VaultBase(vaultB).coin()), coinB);
        _assertLaunched(coinB, vaultB, idB);

        // A trader buys A inside the toll window: A's price moves, B's does not, and A's vault gets the toll.
        (uint160 spB,,,) = manager.getSlot0(idB);
        (uint160 spA,,,) = manager.getSlot0(idA);
        uint256 vaultA0 = weth.balanceOf(vaultA);
        Actor router = new Actor(manager);
        weth.mint(address(manager), 10 ether); // R9: the beforeSwap take is paid from the manager's float
        weth.mint(TRADER, 1 ether);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        router.swap(_key(coinA), !_coinIsToken0(), -0.1 ether);
        vm.stopPrank();
        (uint160 spA1,,,) = manager.getSlot0(idA);
        (uint160 spB1,,,) = manager.getSlot0(idB);
        assertTrue(spA1 != spA, "A moved");
        assertEq(spB1, spB, "B did not");
        assertEq(weth.balanceOf(vaultA) - vaultA0, 0.1 ether * TOLL_START_BPS / 1e4, "clock started: toll");
        assertEq(weth.balanceOf(vaultB), 0);
    }

    function test_launch_gas() public {
        _forceSide();
        LauncherFactory.Params memory p = _params(LauncherFactory.Mode.Redeem);
        vm.prank(LAUNCHER);
        uint256 g = gasleft();
        factory.launch{value: 1 ether + LAUNCH_FEE}(p);
        emit log_named_uint("launch() Redeem + 1 ETH first buy, gas", g - gasleft());
        p.mode = LauncherFactory.Mode.Burn;
        _forceSide();
        vm.prank(LAUNCHER);
        g = gasleft();
        factory.launch{value: LAUNCH_FEE}(p);
        emit log_named_uint("launch() Burn, no first buy, gas", g - gasleft());
    }

    // ---- helpers ----

    function _params(LauncherFactory.Mode mode) internal pure returns (LauncherFactory.Params memory) {
        return LauncherFactory.Params({
            name: "Coin",
            symbol: "COIN",
            imageURI: "ipfs://coin",
            metadataURI: "https://surcofi.com/meta.json",
            mode: mode,
            feeBps: FEE_BPS,
            creatorBps: CREATOR_BPS,
            creatorPayout: CREATOR
        });
    }

    function _launch(LauncherFactory.Mode mode, uint256 firstBuy) internal returns (address, address, PoolId) {
        _forceSide();
        vm.prank(LAUNCHER);
        return factory.launch{value: firstBuy + LAUNCH_FEE}(_params(mode));
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

    function _key(address coin) internal pure returns (PoolKey memory) {
        (address a, address b) = coin < WETH ? (coin, WETH) : (WETH, coin);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), LP_FEE, TICK_SPACING, IHooks(HOOK));
    }

    function _storedKeyId(BurnVault vault) internal view returns (PoolId) {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = vault.poolKey();
        return PoolKey(c0, c1, fee, spacing, hooks).toId();
    }

    function _assertLaunched(address coin, address vault, PoolId id) internal view {
        PoolKey memory key = _key(coin);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(id), "id is the COIN/WETH pool");
        assertEq(Currency.unwrap(_coinIsToken0() ? key.currency0 : key.currency1), coin, "sort order forced");

        // Initialised at the start tick.
        (uint160 sp, int24 tick,,) = manager.getSlot0(id);
        int24 start = _coinIsToken0() ? START : -START;
        assertEq(sp, TickMath.getSqrtPriceAtTick(start), "initialised");
        assertEq(tick, start);

        // The whole supply is locked in one single-sided position on the coin's side, owned by the factory.
        (int24 lo, int24 hi) = _coinIsToken0()
            ? (start, TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), start);
        uint128 liq = manager.getPositionLiquidity(id, Position.calculatePositionKey(address(factory), lo, hi, 0));
        assertGt(liq, 0, "one position");
        LaunchToken token = LaunchToken(coin);
        uint256 held = token.balanceOf(address(manager)) + token.balanceOf(CREATOR);
        assertEq(held, token.totalSupply(), "every coin is in the pool or bought by the creator");
        assertLe(SUPPLY - token.totalSupply(), 1e5, "only liquidity-rounding dust burned");

        // Registered with the hook, clock started.
        LauncherHook.Coin memory c = hook.coin(id);
        assertEq(c.vault, vault, "hook registered");
        assertEq(c.feeBps, FEE_BPS);
        assertEq(c.coinIsToken0, _coinIsToken0());
        assertEq(c.launchedAt, block.timestamp, "clock started");

        // The vault is wired to this coin, the Safe and the creator.
        VaultBase v = VaultBase(vault);
        assertEq(address(v.coin()), coin);
        assertEq(v.safe(), SAFE);
        assertEq(v.creatorPayout(), CREATOR);
        assertEq(v.creatorBps(), CREATOR_BPS);
        assertEq(token.name(), "Coin");
        assertEq(token.symbol(), "COIN");
        assertEq(token.imageURI(), "ipfs://coin");
    }

    function _expectLaunchRevert(LauncherFactory.Params memory p, bytes4 err) internal {
        vm.expectRevert(err);
        vm.prank(LAUNCHER);
        factory.launch{value: LAUNCH_FEE}(p);
    }

    /// Exactly one Launched event, every field checked.
    function _assertLaunchedEvent(
        address coin,
        address vault,
        PoolId id,
        LauncherFactory.Mode mode,
        uint256 firstBuyWeth,
        uint256 coinsBought
    ) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != LauncherFactory.Launched.selector) continue;
            found++;
            assertEq(logs[i].topics.length, 4, "three indexed fields");
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(coin))), "coin");
            assertEq(logs[i].topics[2], PoolId.unwrap(id), "id");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(LAUNCHER))), "msg.sender");
            (address v, LauncherFactory.Mode m, uint16 fee, uint16 cbps, uint256 w, uint256 c) = abi.decode(
                logs[i].data, (address, LauncherFactory.Mode, uint16, uint16, uint256, uint256)
            );
            assertEq(v, vault, "vault");
            assertEq(uint8(m), uint8(mode), "mode");
            assertEq(fee, FEE_BPS, "feeBps");
            assertEq(cbps, CREATOR_BPS, "creatorBps");
            assertEq(w, firstBuyWeth, "firstBuyWeth");
            assertEq(c, coinsBought, "coinsBought");
        }
        assertEq(found, 1, "one Launched event");
    }
}

contract LauncherFactoryCoinToken0Test is LauncherFactoryBase {
    function _coinIsToken0() internal pure override returns (bool) {
        return true;
    }
}

contract LauncherFactoryCoinToken1Test is LauncherFactoryBase {
    function _coinIsToken0() internal pure override returns (bool) {
        return false;
    }
}
