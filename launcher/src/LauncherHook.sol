// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FeeMath} from "./FeeMath.sol";
import {EMA_WINDOW, MIN_FEE_BPS, MAX_FEE_BPS} from "./Constants.sol";

/// @notice The one hook behind every launcher coin's COIN/WETH pool. Any router may swap. Each swap pays
///         the coin's fee in WETH, straight from the PoolManager to that coin's vault. Liquidity is
///         locked: only the factory adds it, nobody removes it, nobody donates. No owner, no upgrade.
/// @dev Fee rule (R8): the fee is the same share of the trader's WETH leg in all four cases, where the
///      leg is what the trader pays in WETH on a buy and what the trader receives in WETH on a sell.
///      With r = bps / 1e4:
///        - exact-in buy, exact-out sell (WETH specified, charged in beforeSwap): fee = r × |amountSpecified|
///        - exact-out buy (WETH unspecified, afterSwap): fee = poolIn × bps / (1e4 − bps), so fee = r × (poolIn + fee)
///        - exact-in sell (WETH unspecified, afterSwap): fee = poolOut × bps / (1e4 + bps), so fee = r × (poolOut − fee)
///      All round down. A fee of 0 skips the take. The hook takes the fee (its delta −fee) and returns +fee,
///      which the manager charges to the swapper.
///      The beforeSwap take is paid from the PoolManager's WETH float, before the trader settles.
///      A price-limited partial fill on exact-in buy / exact-out sell is charged on the requested amount, not
///      the filled one: the fee is fixed before the swap, and afterSwap can only adjust the unspecified currency.
contract LauncherHook {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint160 public constant ALL_HOOK_MASK = 0x3FFF;
    /// beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap | beforeDonate
    /// | beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 public constant REQUIRED_FLAGS = 0x2AEC;

    struct Coin {
        address vault;
        uint16 feeBps;
        uint64 launchedAt;
        bool coinIsToken0;
        int56 emaQ; // tick EMA × EMA_WINDOW: fixed point, so a step smaller than one tick still counts
        uint64 emaTs;
    }

    IPoolManager public immutable manager;
    address public immutable factory;
    address public immutable weth;

    mapping(PoolId => Coin) internal coins;

    error BadHookAddress();
    error OnlyPoolManager();
    error OnlyFactory();
    error NotRegistered();
    error AlreadyRegistered();
    error NotWethPool();
    error LiquidityLocked();
    error NoDonate();
    error BadFee();
    error ClockStarted();

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(IPoolManager manager_, address factory_, address weth_) {
        if ((uint160(address(this)) & ALL_HOOK_MASK) != REQUIRED_FLAGS) revert BadHookAddress();
        manager = manager_;
        factory = factory_;
        weth = weth_;
    }

    // ---- factory ----

    /// @notice Records a coin's pool. A pool cannot initialise until it is registered, so this runs first.
    function register(PoolKey calldata key, address vault, uint16 feeBps) external onlyFactory {
        bool coinIsToken0 = Currency.unwrap(key.currency1) == weth;
        if (!coinIsToken0 && Currency.unwrap(key.currency0) != weth) revert NotWethPool();
        Coin storage c = coins[key.toId()];
        if (c.vault != address(0)) revert AlreadyRegistered();
        if (feeBps < MIN_FEE_BPS || feeBps > MAX_FEE_BPS) revert BadFee();
        c.vault = vault;
        c.feeBps = feeBps;
        c.coinIsToken0 = coinIsToken0;
    }

    /// @notice Starts the sniper toll. Until then the pool charges the plain feeBps (the factory's first buy).
    function startClock(PoolId id) external onlyFactory {
        Coin storage c = coins[id];
        if (c.launchedAt != 0) revert ClockStarted();
        c.launchedAt = uint64(block.timestamp);
    }

    // ---- views ----

    function coin(PoolId id) external view returns (Coin memory) {
        return coins[id];
    }

    /// @notice The block-lagged tick EMA. 0 until the pool's first swap seeds it.
    function emaTick(PoolId id) external view returns (int24) {
        // emaQ lies between seeded ticks × EMA_WINDOW (see _updateEma), so the quotient fits int24.
        return int24(int256(coins[id].emaQ) / int256(EMA_WINDOW));
    }

    // ---- hooks ----

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (coins[key.toId()].vault == address(0)) revert NotRegistered();
        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyManager returns (bytes4) {
        if (sender != factory) revert OnlyFactory();
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert LiquidityLocked();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NoDonate();
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Coin storage c = coins[id];
        _updateEma(c, id);
        if (sender == c.vault || !_wethSpecified(c, params)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        int256 s = params.amountSpecified;
        uint256 leg = s < 0 ? uint256(-s) : uint256(s); // non-negative, so lossless; -s reverts at int256.min
        int128 fee = _take(c, leg * _bps(c) / 1e4);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        Coin storage c = coins[key.toId()];
        if (sender == c.vault || _wethSpecified(c, params)) return (this.afterSwap.selector, 0);
        // The pool's WETH delta, caller's view: > 0 the pool pays the trader (sell), < 0 the trader pays (buy).
        int256 leg = c.coinIsToken0 ? delta.amount1() : delta.amount0();
        uint256 bps = _bps(c);
        uint256 fee = leg > 0 ? uint256(leg) * bps / (1e4 + bps) : uint256(-leg) * bps / (1e4 - bps);
        return (this.afterSwap.selector, _take(c, fee));
    }

    // ---- internals ----

    function _bps(Coin storage c) internal view returns (uint256) {
        return FeeMath.tollBps(block.timestamp, c.launchedAt, c.feeBps);
    }

    function _take(Coin storage c, uint256 fee) internal returns (int128) {
        if (fee == 0) return 0;
        manager.take(Currency.wrap(weth), c.vault, fee);
        return fee.toInt128();
    }

    /// @dev Same rule as Hooks.afterSwap: currency0 is specified when (exact-in) == zeroForOne.
    ///      WETH is currency0 exactly when the coin is not.
    function _wethSpecified(Coin storage c, IPoolManager.SwapParams calldata params) internal view returns (bool) {
        return ((params.amountSpecified < 0) == params.zeroForOne) != c.coinIsToken0;
    }

    /// @dev Once per block, step toward the pre-swap tick (the price the previous block closed at) by
    ///      min(dt, EMA_WINDOW) / EMA_WINDOW. Swaps later in the same block cannot move it. The first swap seeds it.
    function _updateEma(Coin storage c, PoolId id) internal {
        uint64 last = c.emaTs;
        if (last == block.timestamp) return;
        (, int24 tick,,) = manager.getSlot0(id);
        int256 target = int256(tick) * int256(EMA_WINDOW);
        if (last == 0) {
            c.emaQ = int56(target);
        } else {
            uint256 dt = block.timestamp - last;
            if (dt > EMA_WINDOW) dt = EMA_WINDOW;
            int256 ema = c.emaQ;
            // The step never exceeds |target - ema| (dt <= window, division truncates toward zero), so the result
            // lies between ema and target, both within ±887272 × 1800 < 2^31, and fits int56.
            c.emaQ = int56(ema + (target - ema) * int256(dt) / int256(EMA_WINDOW));
        }
        c.emaTs = uint64(block.timestamp);
    }
}
