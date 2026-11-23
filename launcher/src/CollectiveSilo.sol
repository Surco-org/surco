// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPintoSilo} from "chirp/interfaces/IPintoSilo.sol";
import {IPintoConvert} from "./interfaces/IPintoConvert.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LauncherHook} from "./LauncherHook.sol";
import {VeChirp} from "./VeChirp.sol";
import {IPintoPeg} from "./VaultBase.sol";
import {FeeMath} from "./FeeMath.sol";
import {PintoRoute} from "./PintoRoute.sol";
import {PriceGuard} from "./PriceGuard.sol";
import {
    WETH,
    PINTO,
    PINTO_DIAMOND,
    LP_FEE,
    TICK_SPACING,
    TOLL_WINDOW,
    MAX_CONVERT_WETH,
    MAX_BUYBACK_PINTO,
    MAX_TICK_DRIFT,
    COIN_TOL_BPS,
    EMA_WINDOW,
    LAMBDA_LAMBDA,
    MERGE_ABOVE_STEMS,
    MERGE_GAS
} from "./Constants.sol";

/// @notice Shared Pinto Silo vault funded by the flat 0.0001 ETH launch fee (in WETH) and voluntary `seed()` Pinto.
///         Principal is never withdrawn. At peg, `plant()` books Silo yield into today's UTC day bucket; once a day
///         completes, `distribute()` withdraws a coin's veChirp-weighted Pinto share, buys that coin through its
///         locked Uniswap v4 pool (EMA price-guarded), and credits 100% of bought coins for veChirp NFT owners to
///         `claim()`. No owner, no pause, no upgrade.
contract CollectiveSilo is IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int128;
    using StateLibrary for IPoolManager;

    uint8 internal constant EXTERNAL_MODE = 0;
    /// @notice Minimum per-(coin, day) Pinto entitlement (0.01 Pinto, 6 decimals) required to distribute/block claims.
    ///         Sub-cent dust stays in permanent Silo principal so un-swappable dust can never brick `claim()`.
    uint256 public constant MIN_DAY_ENTITLED = 10_000;
    /// @dev Transient-storage reentrancy lock slot: keccak256("launcher.CollectiveSilo.lock").
    uint256 private constant LOCK_SLOT = 0x5c68f2c2f957a29b4137927be13f0cf4168419d47c2182d394816f18f2b74102;
    IPintoSilo internal constant SILO = IPintoSilo(PINTO_DIAMOND);
    IPintoConvert internal constant CONVERT = IPintoConvert(PINTO_DIAMOND);

    IPoolManager public immutable manager;
    LauncherHook public immutable hook;
    VeChirp public immutable veChirp;

    /// @notice Total Pinto deposited in the Silo (principal + unspent planted yield, 6 decimals).
    uint256 public siloPinto;
    /// @notice Planted Pinto not yet spent on coin distributions (part of `siloPinto`).
    uint256 public yieldPinto;

    mapping(int96 => uint256) public stemAmount;
    mapping(int96 => uint256) public yieldAt;
    int96[] internal _yieldStems;

    /// @notice Planted Pinto allocated to day `d`, and the total veChirp weight locked on day `d`.
    mapping(uint32 => uint256) public dayPinto;
    mapping(uint32 => uint256) public dayTotalWeight;

    /// @notice How much of `(coin, day)`'s Pinto entitlement has already been swapped into coins.
    mapping(address => mapping(uint32 => uint256)) public coinDayPaidPinto;
    /// @notice Total coins bought and claimable by veChirp lockers for `(coin, day)`.
    mapping(address => mapping(uint32 => uint256)) public dayCoinsBought;

    /// @notice Last UTC day already claimed for `lockId` (0 = never claimed yet).
    mapping(uint256 => uint32) public lastClaimedDay;

    event Converted(uint256 wethIn, uint256 pintoOut, uint256 tip);
    event Seeded(address indexed caller, uint256 amount);
    event Planted(uint32 indexed day, uint256 beans, uint256 totalWeight, bool toPrincipal);
    event Distributed(address indexed coin, uint256 pintoIn, uint256 coinsBought, uint256 tip);
    event Claimed(uint256 indexed lockId, address indexed recipient, address indexed coin, uint256 amount, uint32 throughDay);

    error ZeroAddress();
    error Locked();
    error NothingPending();
    error ZeroBatch();
    error ZeroOut();
    error PayFailed();
    error ApproveFailed();
    error ShortDeposit();
    error ShortWithdraw();
    error ShortPlant();
    error OnlyManager();
    error UnknownCoin();
    error TollActive();
    error DayNotFinished();
    error BadDaysOrder();
    error NoEma();
    error TickDrift();
    error Slippage();
    error PartialFill();
    error NotClaimant();
    error ShortMerge();
    error OnlySelf();
    error MergeGas();

    modifier lock() {
        bool held;
        assembly {
            held := tload(LOCK_SLOT)
        }
        if (held) revert Locked();
        assembly {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly {
            tstore(LOCK_SLOT, 0)
        }
    }

    constructor(IPoolManager manager_, LauncherHook hook_, VeChirp veChirp_) {
        if (address(manager_) == address(0) || address(hook_) == address(0) || address(veChirp_) == address(0)) {
            revert ZeroAddress();
        }
        manager = manager_;
        hook = hook_;
        veChirp = veChirp_;
    }

    // ---- funding (principal, never withdrawn) ----

    /// @notice Converts up to MAX_CONVERT_WETH of accumulated launch-fee WETH into Silo Pinto (0.5% WETH tip).
    function convert() external lock {
        uint256 bal = IERC20(WETH).balanceOf(address(this));
        uint256 batch = bal < MAX_CONVERT_WETH ? bal : MAX_CONVERT_WETH;
        if (batch == 0) revert NothingPending();
        uint256 tip = FeeMath.tip(batch);
        uint256 wethIn = batch - tip;

        uint256 pintoOut = PintoRoute.wethToPinto(wethIn);
        if (pintoOut == 0) revert ZeroOut();
        _deposit(pintoOut);
        if (tip != 0 && !IERC20(WETH).transfer(msg.sender, tip)) revert PayFailed();
        emit Converted(wethIn, pintoOut, tip);
    }

    /// @notice Books Pinto sent to this contract by plain transfer into permanent Silo principal.
    function seed() external lock {
        uint256 amount = IERC20(PINTO).balanceOf(address(this));
        if (amount == 0) revert NothingPending();
        _deposit(amount);
        emit Seeded(msg.sender, amount);
    }

    // ---- daily yield planting ----

    /// @notice At peg, plants Silo yield into today's UTC day bucket. If no Chirp is staked today, planted Pinto
    ///         stays in permanent Silo principal rather than stranding. Below peg it returns cleanly.
    function plant() external lock returns (uint256 beans) {
        if (!IPintoPeg(PINTO_DIAMOND).abovePeg()) return 0;
        int96 stem;
        (beans, stem) = _plant();
        if (beans == 0) return 0;

        uint32 today = veChirp.currentDay();
        uint256 totalW = veChirp.totalWeightAt(today);
        if (totalW == 0) {
            emit Planted(today, beans, 0, true);
            return beans;
        }
        if (yieldAt[stem] == 0) _yieldStems.push(stem);
        yieldAt[stem] += beans;
        yieldPinto += beans;
        dayPinto[today] += beans;
        dayTotalWeight[today] = totalW;
        emit Planted(today, beans, totalW, false);

        if (_yieldStems.length > MERGE_ABOVE_STEMS) {
            if (gasleft() < MERGE_GAS * 64 / 63) revert MergeGas();
            try this.mergeYieldStemsSelf() {} catch {}
        }
    }

    /// @notice Merges all finished (non-germinating) yield stems into one Silo deposit via Pinto's LAMBDA_LAMBDA
    ///         convert, preserving 100% of Pinto and Stalk while preventing `_yieldStems` dust fragmentation.
    function mergeYieldStems() external lock {
        _mergeYieldStems();
    }

    /// @dev Self-only wrapper so `plant()` can catch merge failures atomically without aborting planting.
    function mergeYieldStemsSelf() external {
        if (msg.sender != address(this)) revert OnlySelf();
        _mergeYieldStems();
    }

    function yieldStems() external view returns (int96[] memory) {
        return _yieldStems;
    }

    // ---- yield -> coin buyback distribution ----

    /// @notice Buys `coin` using its veChirp-weighted Pinto share across completed past `days[]` (strictly ascending,
    ///         each `< today`), capped at `min(maxPinto, MAX_BUYBACK_PINTO)`. Caller keeps 0.5% Pinto tip.
    function distribute(address coin, uint32[] calldata daysList, uint256 maxPinto) external lock returns (uint256 coinsBought) {
        if (maxPinto == 0) revert ZeroBatch();
        if (daysList.length == 0) revert NothingPending();

        PoolKey memory key = _poolKey(coin);
        {
            LauncherHook.Coin memory c = hook.coin(key.toId());
            if (c.vault == address(0)) revert UnknownCoin();
            if (block.timestamp < uint256(c.launchedAt) + TOLL_WINDOW) revert TollActive();
        }

        uint256 cap = maxPinto < MAX_BUYBACK_PINTO ? maxPinto : MAX_BUYBACK_PINTO;
        (uint256[] memory takes, uint256 batch) = _collectBatch(coin, daysList, cap);
        if (batch == 0) revert NothingPending();

        _withdrawYield(batch);
        uint256 tip = FeeMath.tip(batch);
        uint256 pintoIn = batch - tip;
        uint256 wethIn = PintoRoute.pintoToWeth(pintoIn);
        if (wethIn == 0) revert ZeroOut();

        coinsBought = abi.decode(manager.unlock(abi.encode(key, wethIn)), (uint256));
        if (coinsBought == 0) revert ZeroOut();

        _creditDays(coin, daysList, takes, batch, coinsBought);
        if (tip != 0 && !IERC20(PINTO).transfer(msg.sender, tip)) revert PayFailed();
        emit Distributed(coin, pintoIn, coinsBought, tip);
    }

    function _collectBatch(address coin, uint32[] calldata daysList, uint256 cap)
        private
        returns (uint256[] memory takes, uint256 batch)
    {
        uint32 today = veChirp.currentDay();
        takes = new uint256[](daysList.length);
        uint32 prevDay;
        for (uint256 i; i < daysList.length; i++) {
            uint32 d = daysList[i];
            if (d >= today) revert DayNotFinished();
            if (i > 0 && d <= prevDay) revert BadDaysOrder();
            prevDay = d;
            if (batch >= cap) break;

            uint256 rem = _coinDayRemaining(coin, d);
            if (rem == 0) continue;
            uint256 avail = cap - batch;
            uint256 take;
            if (rem <= avail) {
                take = rem;
            } else {
                // Never allow a partial fill that takes < MIN_DAY_ENTITLED or leaves < MIN_DAY_ENTITLED unpaid
                // (which would otherwise strand `claim()` on an un-swappable dust tail).
                if (avail < MIN_DAY_ENTITLED) break;
                if (rem - avail < MIN_DAY_ENTITLED) {
                    if (rem < 2 * MIN_DAY_ENTITLED) break;
                    take = rem - MIN_DAY_ENTITLED;
                } else {
                    take = avail;
                }
            }
            takes[i] = take;
            coinDayPaidPinto[coin][d] += take;
            batch += take;
        }
    }

    function _entitled(uint256 dp, uint256 cw, uint256 tw) private pure returns (uint256) {
        uint256 e = dp * cw / tw;
        return e < MIN_DAY_ENTITLED ? 0 : e;
    }

    function _coinDayRemaining(address coin, uint32 d) private returns (uint256) {
        uint256 dp = dayPinto[d];
        uint256 tw = dayTotalWeight[d];
        if (dp == 0 || tw == 0) return 0;
        uint256 cw = veChirp.coinWeightAt(coin, d);
        if (cw == 0) return 0;
        uint256 entitled = _entitled(dp, cw, tw);
        if (entitled == 0) return 0;
        uint256 paid = coinDayPaidPinto[coin][d];
        return entitled > paid ? entitled - paid : 0;
    }

    function _creditDays(address coin, uint32[] calldata daysList, uint256[] memory takes, uint256 batch, uint256 coinsBought)
        private
    {
        uint256 n = daysList.length;
        uint256 lastIdx;
        for (uint256 i; i < n; i++) {
            if (takes[i] != 0) lastIdx = i;
        }
        uint256 allocated;
        for (uint256 i; i < n; i++) {
            uint256 tk = takes[i];
            if (tk == 0) continue;
            uint256 share = i == lastIdx ? coinsBought - allocated : coinsBought * tk / batch;
            dayCoinsBought[coin][daysList[i]] += share;
            allocated += share;
        }
    }

    /// @notice Claims earned coins for `lockId` over up to `maxDays` completed past days, stopping at the first coin
    ///         switch (so one call transfers one ERC-20) or any unsettled day with non-zero yield.
    function claim(uint256 lockId, uint32 maxDays) external lock returns (address coin, uint256 payout) {
        address recipient = veChirp.claimantOf(lockId);
        if (recipient == address(0) || msg.sender != recipient) revert NotClaimant();
        uint32 cursor = lastClaimedDay[lockId];
        (uint32 start, uint32 end) = _claimWindow(lockId, cursor, maxDays);
        if (start > end) return (address(0), 0);

        uint32 lastProcessed = cursor;
        for (uint32 d = start; d <= end; d++) {
            (address dayCoin, uint256 addPay, bool stop) = _dayClaim(lockId, d, coin);
            if (stop) break;
            if (addPay > 0) {
                if (coin == address(0)) coin = dayCoin;
                payout += addPay;
            }
            lastProcessed = d;
        }

        if (lastProcessed > cursor) lastClaimedDay[lockId] = lastProcessed;
        if (payout > 0 && coin != address(0)) {
            if (!IERC20(coin).transfer(recipient, payout)) revert PayFailed();
            emit Claimed(lockId, recipient, coin, payout, lastProcessed);
        }
    }

    function _claimWindow(uint256 lockId, uint32 cursor, uint32 maxDays) private view returns (uint32 start, uint32 end) {
        uint32 today = veChirp.currentDay();
        uint32 firstDay = veChirp.firstDayOf(lockId);
        if (today == 0 || maxDays == 0 || firstDay == 0 || firstDay >= today) return (1, 0);
        start = cursor < firstDay ? firstDay : cursor + 1;
        end = today - 1;
        if (start <= end && end - start + 1 > maxDays) end = start + maxDays - 1;
    }

    function _dayClaim(uint256 lockId, uint32 d, address currentCoin)
        private
        returns (address dayCoin, uint256 addPay, bool stop)
    {
        uint256 lw;
        (dayCoin, lw) = veChirp.lockStateAt(lockId, d);
        if (lw == 0 || dayCoin == address(0)) return (address(0), 0, false);
        if (currentCoin != address(0) && dayCoin != currentCoin) return (dayCoin, 0, true);

        uint256 dp = dayPinto[d];
        uint256 tw = dayTotalWeight[d];
        if (dp == 0 || tw == 0) return (dayCoin, 0, false);

        uint256 cw = veChirp.coinWeightAt(dayCoin, d);
        if (cw == 0) return (dayCoin, 0, false);
        uint256 entitled = _entitled(dp, cw, tw);
        if (entitled > 0 && coinDayPaidPinto[dayCoin][d] < entitled) return (dayCoin, 0, true);

        uint256 bought = dayCoinsBought[dayCoin][d];
        if (bought > 0) addPay = bought * lw / cw;
    }

    // ---- Uniswap v4 unlock callback (EMA price-guarded swap WETH -> coin) ----

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (PoolKey memory key, uint256 wethIn) = abi.decode(data, (PoolKey, uint256));
        PoolId id = key.toId();
        LauncherHook.Coin memory c = hook.coin(id);
        if (c.emaTs == 0) revert NoEma();
        (, int24 tick,,) = manager.getSlot0(id);
        int24 ema = _emaNow(c, tick);
        if (tick > ema + MAX_TICK_DRIFT || tick < ema - MAX_TICK_DRIFT) revert TickDrift();
        // Because CollectiveSilo is not the coin's vault, the hook takes its normal feeBps on this buy (feeding the coin's vault).
        uint256 netWeth = wethIn * (1e4 - c.feeBps) / 1e4;
        uint256 minOut = PriceGuard.coinsForWeth(netWeth, ema, c.coinIsToken0) * (1e4 - COIN_TOL_BPS) / 1e4;

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

    // ---- internals ----

    function _poolKey(address coin) internal view returns (PoolKey memory) {
        bool coinIs0 = coin < WETH;
        return PoolKey({
            currency0: Currency.wrap(coinIs0 ? coin : WETH),
            currency1: Currency.wrap(coinIs0 ? WETH : coin),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _emaNow(LauncherHook.Coin memory c, int24 tick) private view returns (int24) {
        uint256 dt = block.timestamp - c.emaTs;
        if (dt > EMA_WINDOW) dt = EMA_WINDOW;
        int256 ema = c.emaQ;
        int256 q = ema + (int256(tick) * int256(EMA_WINDOW) - ema) * int256(dt) / int256(EMA_WINDOW);
        return int24(q / int256(EMA_WINDOW));
    }

    function _deposit(uint256 amount) internal {
        if (amount == 0) return;
        IERC20 token = IERC20(PINTO);
        uint256 before = token.balanceOf(address(this));
        if (!token.approve(address(SILO), amount)) revert ApproveFailed();
        (,, int96 stem) = SILO.deposit(PINTO, amount, EXTERNAL_MODE);
        if (!token.approve(address(SILO), 0)) revert ApproveFailed();
        uint256 pulled = before - token.balanceOf(address(this));
        if (pulled != amount) revert ShortDeposit();
        uint256 prev = stemAmount[stem];
        (uint256 dep,) = SILO.getDeposit(address(this), PINTO, stem);
        if (prev > dep || dep - prev < pulled) revert ShortDeposit();
        stemAmount[stem] = prev + pulled;
        siloPinto += pulled;
    }

    function _plant() internal returns (uint256 beans, int96 stem) {
        (beans, stem) = SILO.plant();
        if (beans == 0) return (0, stem);
        uint256 prev = stemAmount[stem];
        (uint256 dep,) = SILO.getDeposit(address(this), PINTO, stem);
        if (prev > dep || dep - prev < beans) revert ShortPlant();
        stemAmount[stem] = prev + beans;
        siloPinto += beans;
    }

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

    function _mergeYieldStems() private {
        int96 germinating = SILO.getGerminatingStem(PINTO);
        uint256 n = _yieldStems.length;
        uint256 m;
        for (uint256 i; i < n; i++) {
            int96 s = _yieldStems[i];
            if (s < germinating && yieldAt[s] != 0) m++;
        }
        if (m < 2) return;

        int96[] memory from = new int96[](m);
        uint256[] memory amounts = new uint256[](m);
        int96[] memory keep = new int96[](n - m);
        uint256 total;
        (uint256 fi, uint256 ki) = (0, 0);
        for (uint256 i; i < n; i++) {
            int96 s = _yieldStems[i];
            uint256 a = yieldAt[s];
            if (s < germinating && a != 0) {
                (from[fi], amounts[fi]) = (s, a);
                total += a;
                fi++;
            } else {
                keep[ki++] = s;
            }
        }

        (int96 toStem, uint256 fromAmount, uint256 toAmount,,) =
            CONVERT.convert(abi.encode(LAMBDA_LAMBDA, total, PINTO), from, amounts);
        if (fromAmount != total || toAmount != total) revert ShortMerge();

        for (uint256 i; i < m; i++) {
            yieldAt[from[i]] -= amounts[i];
            stemAmount[from[i]] -= amounts[i];
        }
        yieldAt[toStem] += total;
        stemAmount[toStem] += total;
        (uint256 dep,) = SILO.getDeposit(address(this), PINTO, toStem);
        if (dep < stemAmount[toStem]) revert ShortMerge();

        delete _yieldStems;
        _yieldStems.push(toStem);
        for (uint256 i; i < ki; i++) {
            if (keep[i] != toStem && yieldAt[keep[i]] != 0) _yieldStems.push(keep[i]);
        }
    }
}
