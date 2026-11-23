// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {LauncherHook} from "./LauncherHook.sol";
import {BurnVault} from "./BurnVault.sol";
import {RedeemDeployer, BurnDeployer} from "./VaultDeployers.sol";
import {
    WETH,
    SUPPLY,
    MIN_FEE_BPS,
    MAX_FEE_BPS,
    MAX_CREATOR_BPS,
    TICK_SPACING,
    LP_FEE,
    START_FDV_WETH,
    LAUNCH_FEE
} from "./Constants.sol";

/// @notice One call launches a coin: the token, its vault, the COIN/WETH pool on the shared hook at a START_FDV_WETH
///         fully-diluted start, the whole supply locked as single-sided liquidity forever, the creator's optional
///         first buy at the plain fee, then the anti-sniper clock. No owner, no upgrade.
/// @dev    The liquidity position belongs to this factory and the hook refuses every removal, so it is locked.
///         Rounding the position's liquidity down leaves < ~1e4 wei of coin unplaced; launch burns it.
contract LauncherFactory is IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int128;

    enum Mode {
        Redeem,
        Burn
    }

    struct Params {
        string name;
        string symbol;
        string imageURI;
        string metadataURI;
        Mode mode;
        uint16 feeBps;
        uint16 creatorBps;
        address creatorPayout;
    }

    IPoolManager public immutable manager;
    LauncherHook public immutable hook;
    address public immutable safe;
    address public immutable collectiveSilo;
    RedeemDeployer public immutable redeemDeployer;
    BurnDeployer public immutable burnDeployer;
    /// @notice The start tick when the coin is token0 (price = WETH per coin); the coin-as-token1 start is its negation.
    int24 public immutable startTick0;

    event Launched(
        address indexed coin,
        address vault,
        PoolId indexed id,
        address indexed launcher,
        Mode mode,
        uint16 feeBps,
        uint16 creatorBps,
        uint256 firstBuyWeth,
        uint256 coinsBought
    );

    error ZeroAddress();
    error BadFee();
    error BadCreatorBps();
    error EmptyName();
    error BadPayout();
    error OnlyManager();
    error KeptFunds();
    error TransferFailed();
    error InsufficientLaunchFee();

    constructor(IPoolManager manager_, LauncherHook hook_, address safe_, address collectiveSilo_) {
        if (
            address(manager_) == address(0) || address(hook_) == address(0) || safe_ == address(0)
                || collectiveSilo_ == address(0)
        ) revert ZeroAddress();
        manager = manager_;
        hook = hook_;
        safe = safe_;
        collectiveSilo = collectiveSilo_;
        redeemDeployer = new RedeemDeployer();
        burnDeployer = new BurnDeployer();
        startTick0 = _startTick0();
    }

    function launch(Params calldata p) external payable returns (address coin, address vault, PoolId id) {
        if (msg.value < LAUNCH_FEE) revert InsufficientLaunchFee();
        if (p.feeBps < MIN_FEE_BPS || p.feeBps > MAX_FEE_BPS) revert BadFee();
        if (p.creatorBps > MAX_CREATOR_BPS) revert BadCreatorBps();
        if (p.creatorPayout == address(0)) revert ZeroAddress();
        // The dust burn would take the creator's first buy, and the vault's creator share would sit here forever.
        if (p.creatorPayout == address(this)) revert BadPayout();
        if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert EmptyName();

        uint256 firstBuy = msg.value - LAUNCH_FEE;
        LaunchToken token = new LaunchToken(p.name, p.symbol, p.imageURI, p.metadataURI, address(this));
        coin = address(token);
        vault = p.mode == Mode.Redeem
            ? address(redeemDeployer.deploy(token, safe, p.creatorPayout, p.creatorBps))
            : address(burnDeployer.deploy(token, safe, p.creatorPayout, p.creatorBps, manager, hook));

        (PoolKey memory key, uint256 coinsBought) = _openPool(token, vault, p.feeBps, p.creatorPayout, firstBuy);
        id = key.toId();
        if (p.mode == Mode.Burn) burnDeployer.setPoolKey(BurnVault(vault), key);
        emit Launched(coin, vault, id, msg.sender, p.mode, p.feeBps, p.creatorBps, firstBuy, coinsBought);
    }

    /// @dev Register, initialise, lock the supply, forward LAUNCH_FEE to CollectiveSilo, optional first buy, start the
    ///      clock. Ends holding none of the coin and no more WETH or ETH than before the launch.
    function _openPool(LaunchToken token, address vault, uint16 feeBps, address creatorPayout, uint256 firstBuy)
        internal
        returns (PoolKey memory key, uint256 coinsBought)
    {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 ethBefore = address(this).balance - msg.value;

        bool coinIs0 = address(token) < WETH;
        key = PoolKey({
            currency0: Currency.wrap(coinIs0 ? address(token) : WETH),
            currency1: Currency.wrap(coinIs0 ? WETH : address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        hook.register(key, vault, feeBps);
        int24 start = coinIs0 ? startTick0 : -startTick0;
        manager.initialize(key, TickMath.getSqrtPriceAtTick(start));

        IWETH(WETH).deposit{value: msg.value}();
        if (!IERC20(WETH).transfer(collectiveSilo, LAUNCH_FEE)) revert TransferFailed();
        coinsBought = abi.decode(manager.unlock(abi.encode(key, start, firstBuy, creatorPayout)), (uint256));
        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) token.burn(dust);
        hook.startClock(key.toId());

        if (
            token.balanceOf(address(this)) != 0 || IERC20(WETH).balanceOf(address(this)) != wethBefore
                || address(this).balance != ethBefore
        ) revert KeptFunds();
    }

    /// @dev Adds the whole supply as one position on the coin's side of `start`, then, if `wethIn` > 0, buys with it
    ///      for `recipient`. The WETH is settled before the swap, so the hook's beforeSwap fee take is paid from it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (PoolKey memory key, int24 start, uint256 wethIn, address recipient) =
            abi.decode(data, (PoolKey, int24, uint256, address));
        bool coinIs0 = Currency.unwrap(key.currency1) == WETH;
        Currency coin = coinIs0 ? key.currency0 : key.currency1;

        (int24 lo, int24 hi) =
            coinIs0 ? (start, TickMath.maxUsableTick(TICK_SPACING)) : (TickMath.minUsableTick(TICK_SPACING), start);
        (BalanceDelta added,) = manager.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lo, hi, _liquidity(coinIs0, lo, hi).toInt256(), 0), ""
        );
        _pay(coin, (-(coinIs0 ? added.amount0() : added.amount1())).toUint128());
        if (wethIn == 0) return abi.encode(uint256(0));

        _pay(Currency.wrap(WETH), wethIn);
        BalanceDelta swapped = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: !coinIs0,
                amountSpecified: -wethIn.toInt256(),
                sqrtPriceLimitX96: coinIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 out = (coinIs0 ? swapped.amount0() : swapped.amount1()).toUint128();
        manager.take(coin, recipient, out);
        return abi.encode(out);
    }

    function _pay(Currency currency, uint256 amount) internal {
        manager.sync(currency);
        if (!IERC20(Currency.unwrap(currency)).transfer(address(manager), amount)) revert TransferFailed();
        manager.settle();
    }

    /// @dev The most liquidity whose coin amount on [lo, hi] is at most SUPPLY (both roundings go down, the pool's
    ///      amount rounds up, so the pool never asks for more than SUPPLY).
    ///      Coin token0: amount0 = L·Q96·(b − a)/(a·b).  Coin token1: amount1 = L·(b − a)/Q96.
    function _liquidity(bool coinIs0, int24 lo, int24 hi) internal pure returns (uint256) {
        uint256 a = TickMath.getSqrtPriceAtTick(lo);
        uint256 b = TickMath.getSqrtPriceAtTick(hi);
        return coinIs0
            ? FullMath.mulDiv(FullMath.mulDiv(SUPPLY, a, FixedPoint96.Q96), b, b - a)
            : FullMath.mulDiv(SUPPLY, FixedPoint96.Q96, b - a);
    }

    /// @dev Coin as token0: price = START_FDV_WETH / SUPPLY WETH per coin, sqrtPriceX96 = sqrt(price · 2^192).
    ///      getTickAtSqrtPrice floors; the result is rounded to the nearest multiple of TICK_SPACING.
    function _startTick0() internal pure returns (int24) {
        uint160 sqrtPrice = FixedPointMathLib.sqrt(FullMath.mulDiv(START_FDV_WETH, 1 << 192, SUPPLY)).toUint160();
        int24 t = TickMath.getTickAtSqrtPrice(sqrtPrice);
        int24 down = t / TICK_SPACING * TICK_SPACING;
        if (t % TICK_SPACING < 0) down -= TICK_SPACING;
        return (t - down) * 2 >= TICK_SPACING ? down + TICK_SPACING : down;
    }
}
