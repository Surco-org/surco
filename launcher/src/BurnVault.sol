// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {VaultBase} from "./VaultBase.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {LauncherHook} from "./LauncherHook.sol";
import {FeeMath} from "./FeeMath.sol";
import {PintoRoute} from "./PintoRoute.sol";
import {PriceGuard} from "./PriceGuard.sol";
import {WETH, PINTO, MAX_BUYBACK_PINTO, MAX_TICK_DRIFT, COIN_TOL_BPS, EMA_WINDOW} from "./Constants.sol";

/// @notice Burn mode. The vault's Silo Pinto is never withdrawn. At peg, `buyback()` plants the Silo yield, routes
///         a batch of it (the caller's size, at most MAX_BUYBACK_PINTO) Pinto -> cbETH -> WETH -> coin through the coin's own pool, and burns every
///         coin it bought. Below peg there is no yield and it returns at once. Anyone may call it; the caller keeps
///         TIP_BPS of the batch in Pinto.
/// @dev    Only planted Pinto is ever withdrawn, from its own stems (`yieldAt`), newest first, so the principal's
///         deposits and Stalk are untouched: `siloPinto - yieldPinto` never falls. `_stems` is VaultBase's list for
///         `_withdraw`, which this vault never calls; a stem emptied of yield stays in it.
/// @dev    The swap is this vault's own `unlock`, so the hook sees the vault as the swapper and charges no fee. All
///         the WETH the route produces is spent in that swap (a partial fill reverts), keeping VaultBase's invariant.
contract BurnVault is VaultBase, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int128;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    LauncherHook public immutable hook;

    /// @notice The coin's pool, set once by the factory after it registers the pool with the hook.
    PoolKey public poolKey;
    /// @notice Planted Pinto not yet spent on a buyback (raw, 6 decimals). Part of `siloPinto`.
    uint256 public yieldPinto;
    /// @notice Unspent planted Pinto per stem; `_yieldStems` lists the stems holding some, oldest first.
    mapping(int96 => uint256) public yieldAt;
    int96[] internal _yieldStems;

    /// @param pintoIn Pinto routed to the coin (the batch less the tip).
    event BoughtBack(uint256 pintoIn, uint256 coinsBurned, uint256 tip);

    error OnlyFactory();
    error KeySet();
    error BadKey();
    error OnlyManager();
    error NoEma();
    error TickDrift();
    error Slippage();
    error PartialFill();
    error ZeroBatch();

    constructor(
        LaunchToken coin_,
        address safe_,
        address creatorPayout_,
        uint16 creatorBps_,
        IPoolManager manager_,
        LauncherHook hook_
    ) VaultBase(coin_, safe_, creatorPayout_, creatorBps_) {
        if (address(manager_) == address(0) || address(hook_) == address(0)) {
            revert ZeroAddress();
        }
        manager = manager_;
        hook = hook_;
    }

    /// @notice The factory's one call: the coin's pool, which the hook must already list with this vault.
    function setPoolKey(PoolKey calldata key) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (address(poolKey.hooks) != address(0)) revert KeySet();
        LauncherHook.Coin memory c = hook.coin(key.toId());
        address coinSide = Currency.unwrap(c.coinIsToken0 ? key.currency0 : key.currency1);
        if (address(key.hooks) != address(hook) || c.vault != address(this) || coinSide != address(coin)) {
            revert BadKey();
        }
        poolKey = key;
    }

    /// @notice At peg: plant, then spend min(planted, `maxPinto`, MAX_BUYBACK_PINTO) of the planted Pinto buying the
    ///         coin, and burn it. The caller sizes the batch to the pool's depth (R21): the min-out leaves no room for
    ///         more than COIN_TOL_BPS of price impact. Reverts (nothing moves) if the pool's tick is more than
    ///         MAX_TICK_DRIFT from the hook's EMA projected to now, or the coins bought fall short of that EMA's
    ///         price less COIN_TOL_BPS. Below peg it does nothing.
    function buyback(uint256 maxPinto) external lock {
        if (maxPinto == 0) revert ZeroBatch();
        if (_belowPeg()) return;
        (uint256 beans, int96 stem) = _plant();
        if (beans != 0) {
            if (yieldAt[stem] == 0) _yieldStems.push(stem);
            yieldAt[stem] += beans;
            yieldPinto += beans;
        }
        uint256 batch = yieldPinto < MAX_BUYBACK_PINTO ? yieldPinto : MAX_BUYBACK_PINTO;
        if (maxPinto < batch) batch = maxPinto;
        if (batch == 0) revert NothingPending();
        _withdrawYield(batch);

        uint256 tip = FeeMath.tip(batch);
        uint256 pintoIn = batch - tip;
        uint256 wethIn = PintoRoute.pintoToWeth(pintoIn);
        if (wethIn == 0) revert ZeroOut();
        uint256 coins = abi.decode(manager.unlock(abi.encode(wethIn)), (uint256));
        if (coins == 0) revert ZeroOut();
        coin.burn(coins);
        if (tip != 0 && !IERC20(PINTO).transfer(msg.sender, tip)) revert PayFailed();
        emit BoughtBack(pintoIn, coins, tip);
    }

    /// @notice The swap, inside this vault's own unlock: exact `wethIn` of WETH for coins, priced against the
    ///         hook's EMA tick projected to now. Returns the coins bought, which are now this vault's.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        uint256 wethIn = abi.decode(data, (uint256));
        PoolKey memory key = poolKey;
        PoolId id = key.toId();
        LauncherHook.Coin memory c = hook.coin(id);
        if (c.emaTs == 0) revert NoEma(); // emaTick reads 0 until the pool's first swap (also: no key set)
        (, int24 tick,,) = manager.getSlot0(id);
        int24 ema = _emaNow(c, tick);
        if (tick > ema + MAX_TICK_DRIFT || tick < ema - MAX_TICK_DRIFT) revert TickDrift();
        uint256 minOut = PriceGuard.coinsForWeth(wethIn, ema, c.coinIsToken0) * (1e4 - COIN_TOL_BPS) / 1e4;

        bool zeroForOne = !c.coinIsToken0; // WETH in
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = manager.swap(key, IPoolManager.SwapParams(zeroForOne, -wethIn.toInt256(), limit), "");
        (int128 wethDelta, int128 coinDelta) = c.coinIsToken0 ? (d.amount1(), d.amount0()) : (d.amount0(), d.amount1());
        if (wethDelta != -wethIn.toInt128()) revert PartialFill();
        uint256 coins = coinDelta.toUint128();
        if (coins < minOut) revert Slippage();

        manager.sync(Currency.wrap(WETH));
        if (!IERC20(WETH).transfer(address(manager), wethIn)) revert PayFailed();
        manager.settle();
        manager.take(c.coinIsToken0 ? key.currency0 : key.currency1, address(this), coins);
        return abi.encode(coins);
    }

    /// @dev R22: the hook's EMA stepped to now by its own rule (LauncherHook._updateEma, same fixed point). The
    ///      current tick has held since the last swap, which was in block `emaTs`, so this is the true time-weighted
    ///      value; a push earlier in this block has already set `emaTs` to now, so dt = 0 and the stored EMA stands.
    function _emaNow(LauncherHook.Coin memory c, int24 tick) private view returns (int24) {
        uint256 dt = block.timestamp - c.emaTs;
        if (dt > EMA_WINDOW) dt = EMA_WINDOW;
        int256 ema = c.emaQ;
        int256 q = ema + (int256(tick) * int256(EMA_WINDOW) - ema) * int256(dt) / int256(EMA_WINDOW);
        // q lies between the stored EMA and tick x EMA_WINDOW, both ticks x EMA_WINDOW, so q / EMA_WINDOW fits int24.
        return int24(q / int256(EMA_WINDOW));
    }

    /// @dev Withdraws `amount` of planted Pinto, newest planted stem first. Never touches principal.
    function _withdrawYield(uint256 amount) private {
        yieldPinto -= amount;
        siloPinto -= amount;
        IERC20 token = IERC20(PINTO);
        uint256 before = token.balanceOf(address(this));
        uint256 left = amount;
        while (left != 0) {
            int96 stem = _yieldStems[_yieldStems.length - 1];
            uint256 have = yieldAt[stem];
            uint256 take = have < left ? have : left;
            SILO.withdrawDeposit(PINTO, stem, take, EXTERNAL_MODE);
            yieldAt[stem] = have - take;
            stemAmount[stem] -= take;
            if (take == have) _yieldStems.pop();
            left -= take;
        }
        if (token.balanceOf(address(this)) - before != amount) revert ShortWithdraw();
    }
}
