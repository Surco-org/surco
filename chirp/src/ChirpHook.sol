// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChirpBook} from "./ChirpBook.sol";
import {RatioSqrt} from "./RatioSqrt.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice The only swap door. The v4 pool is the price sticker and holds no tokens.
///         A swap on Uniswap's router reverts here. Trades fill on the book, then this contract
///         moves the sticker to the book's price.
contract ChirpHook is IHooks, IUnlockCallback {
    uint160 public constant ALL_HOOK_MASK = 0x3FFF;
    uint160 public constant REQUIRED_FLAGS = 0x2AE8;

    ChirpBook public immutable book;
    IPoolManager public immutable manager;
    Currency internal immutable currency0;
    Currency internal immutable currency1;
    bool internal immutable chirpIsToken0;

    /// @dev Set for the whole trade, including the sticker unlock. A callback cannot start another one.
    bool private swapping;

    error BadHookAddress();
    error LiquidityLocked();
    error OnlyHookSwap();
    error OnlyPoolManager();
    error OnlyFactory();
    error Slippage();
    error ApproveFailed();
    error PullFailed();
    error Locked();
    error ZeroAddress();

    constructor(ChirpBook book_, IPoolManager manager_) {
        if ((uint160(address(this)) & ALL_HOOK_MASK) != REQUIRED_FLAGS) revert BadHookAddress();
        if (address(manager_) == address(0)) revert ZeroAddress();
        book = book_;
        manager = manager_;

        address chirpAddr = address(book_.chirp());
        address pintoAddr = book_.pinto();
        if (chirpAddr < pintoAddr) {
            currency0 = Currency.wrap(chirpAddr);
            currency1 = Currency.wrap(pintoAddr);
            chirpIsToken0 = true;
        } else {
            currency0 = Currency.wrap(pintoAddr);
            currency1 = Currency.wrap(chirpAddr);
            chirpIsToken0 = false;
        }
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
    }

    /// @notice Q64.96 sticker for the book's raw reserves, sorted into token1/token0.
    function sqrtPriceX96() public view returns (uint160) {
        uint256 pintoRaw = book.virtualPinto() + book.pintoInCurve();
        uint256 chirpRaw = book.chirpReserve();
        if (chirpIsToken0) return RatioSqrt.sqrtPriceX96(pintoRaw, chirpRaw);
        return RatioSqrt.sqrtPriceX96(chirpRaw, pintoRaw);
    }

    /// @notice Initializes the empty pool at the opening price. The factory calls this once.
    function launch() external {
        if (msg.sender != book.factory()) revert OnlyFactory();
        manager.initialize(poolKey(), sqrtPriceX96());
    }

    function swapExactPintoForChirp(uint256 pintoIn, uint256 minChirp, address recipient)
        external
        returns (uint256 chirpOut)
    {
        if (swapping) revert Locked();
        swapping = true;

        IERC20 token = IERC20(book.pinto());
        if (!token.transferFrom(msg.sender, address(this), pintoIn)) revert PullFailed();
        if (!token.approve(address(book), pintoIn)) revert ApproveFailed();
        chirpOut = book.buy(address(this), pintoIn, recipient);
        if (!token.approve(address(book), 0)) revert ApproveFailed();
        if (chirpOut < minChirp) revert Slippage();
        _syncSticker();

        swapping = false;
    }

    function swapExactChirpForPinto(uint256 chirpIn, uint256 minPinto, address recipient)
        external
        returns (uint256 pintoOut)
    {
        if (swapping) revert Locked();
        swapping = true;

        IERC20 token = IERC20(address(book.chirp()));
        if (!token.transferFrom(msg.sender, address(this), chirpIn)) revert PullFailed();
        if (!token.approve(address(book), chirpIn)) revert ApproveFailed();
        pintoOut = book.sell(address(this), chirpIn, recipient);
        if (!token.approve(address(book), 0)) revert ApproveFailed();
        if (pintoOut < minPinto) revert Slippage();
        _syncSticker();

        swapping = false;
    }

    /// @dev Zero liquidity, so a 1-wei exact-in lands on the limit and both currency deltas stay 0.
    ///      The pool never holds Chirp or Pinto. Skip when the Q64.96 price did not move.
    function _syncSticker() internal {
        PoolKey memory key = poolKey();
        uint160 target = sqrtPriceX96();
        (uint160 current,,,) = StateLibrary.getSlot0(manager, key.toId());
        if (target == current) return;
        manager.unlock(abi.encode(target < current, target));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        if (!swapping) revert Locked();
        (bool zeroForOne, uint160 target) = abi.decode(data, (bool, uint160));
        manager.swap(
            poolKey(),
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: target}),
            ""
        );
        return "";
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert LiquidityLocked();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert LiquidityLocked();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert LiquidityLocked();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert LiquidityLocked();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert LiquidityLocked();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert OnlyHookSwap();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert OnlyHookSwap();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert LiquidityLocked();
    }
}
