// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {LibString} from "solmate/src/utils/LibString.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LauncherHook} from "./LauncherHook.sol";
import {WETH, LP_FEE, TICK_SPACING} from "./Constants.sol";

/// @notice Minimal ERC-721 veChirp gauge. Users lock Chirp for 2..365 UTC days (linear decay: weight = amount *
///         remainingDays / 365) or toggle permanent max-lock (100% weight until toggled off, which starts a 365-day
///         decay). Every lock backs one factory-launched coin; changes take effect at `today + 1` so today's weights
///         are frozen and flash-staking/sunrise-hopping is impossible. No owner, no pause, no upgrade, zero external
///         dependency on Pinto or CollectiveSilo (unlocked Chirp is always withdrawable).
contract VeChirp is ERC721 {
    uint32 public constant MIN_DAYS = 2;
    uint32 public constant MAX_DAYS = 365;
    /// @notice Minimum Chirp per lock (>= MAX_DAYS wei) so every active lock always has weight >= 1 on every active day.
    uint128 public constant MIN_LOCK_AMOUNT = 365;
    uint256 internal constant DAY = 1 days;
    /// @dev Transient-storage reentrancy lock slot: keccak256("launcher.VeChirp.lock").
    uint256 private constant LOCK_SLOT = 0x7c8f1b529c2d004f878cf5f04637221931f0fd41d0f9438f7c4f3164d20d4391;

    struct Snap {
        uint32 fromDay;
        uint32 endDay; // 0 when permanent
        bool permanent;
        address coin;
        uint128 amount;
    }

    /// @dev Exact scaled-integer daily track. Decaying weight is stored in `Chirp * days` (`bias`, `slope`) and
    ///      divided by MAX_DAYS only when writing `weightAt[day]`, eliminating rounding drift over 365 days.
    struct Track {
        uint32 lastDay;
        uint256 perm;
        uint256 bias;
        uint256 slope;
        mapping(uint32 => int256) permDelta;
        mapping(uint32 => int256) biasDelta;
        mapping(uint32 => int256) slopeDelta;
        mapping(uint32 => uint256) weightAt;
    }

    IERC20 public immutable chirp;
    LauncherHook public immutable hook;
    string public baseURI;

    uint256 public nextId = 1;
    uint256 public totalLocked;

    mapping(uint256 => Snap[]) internal _snaps;
    /// @dev Preserved on withdraw() so the former owner can still claim past rewards from CollectiveSilo.
    mapping(uint256 => address) public lastOwner;

    Track internal _global;
    mapping(address => Track) internal _byCoin;

    event Locked(uint256 indexed id, address indexed owner, address indexed coin, uint128 amount, uint32 endDay, bool permanent, uint32 effDay);
    event Added(uint256 indexed id, uint128 added, uint128 newAmount, uint32 effDay);
    event Extended(uint256 indexed id, uint32 newEndDay, uint32 effDay);
    event PermanentSet(uint256 indexed id, bool permanent, uint32 endDay, uint32 effDay);
    event CoinSwitched(uint256 indexed id, address indexed oldCoin, address indexed newCoin, uint32 effDay);
    event Withdrawn(uint256 indexed id, address indexed owner, uint128 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BadDuration();
    error UnknownCoin();
    error NotOwner();
    error IsPermanent();
    error StillLocked();
    error SameCoin();
    error TransferFailed();
    error LockedReentrancy();
    error NotStepped();
    error FutureDay();

    modifier nonReentrant() {
        bool held;
        assembly {
            held := tload(LOCK_SLOT)
        }
        if (held) revert LockedReentrancy();
        assembly {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly {
            tstore(LOCK_SLOT, 0)
        }
    }

    constructor(IERC20 chirp_, LauncherHook hook_, string memory baseURI_) ERC721("veChirp", "veCHIRP") {
        if (address(chirp_) == address(0) || address(hook_) == address(0)) revert ZeroAddress();
        chirp = chirp_;
        hook = hook_;
        baseURI = baseURI_;
        _global.lastDay = currentDay();
    }

    function currentDay() public view returns (uint32) {
        return uint32(block.timestamp / DAY);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (_ownerOf[id] == address(0)) revert NotOwner();
        return string.concat(baseURI, LibString.toString(id));
    }

    /// @notice Who is entitled to claim rewards for `id` (current NFT owner, or withdrawing owner after burn).
    function claimantOf(uint256 id) external view returns (address) {
        address o = _ownerOf[id];
        return o != address(0) ? o : lastOwner[id];
    }

    // ---- user lock actions ----

    /// @notice Locks `amount` Chirp backing `coin`, minting a veChirp NFT. Takes effect on `today + 1`.
    function lock(uint128 amount, uint32 lockDays, bool permanent, address coin)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (amount < MIN_LOCK_AMOUNT) revert ZeroAmount();
        _requireRegistered(coin);
        uint32 today = currentDay();
        uint32 eff = today + 1;
        uint32 endDay;
        if (permanent) {
            endDay = 0;
        } else {
            if (lockDays < MIN_DAYS || lockDays > MAX_DAYS) revert BadDuration();
            endDay = eff + lockDays;
        }

        _stepAll(_global, today);
        _stepCoin(coin, today);

        if (!chirp.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalLocked += amount;

        id = nextId++;
        Snap memory next = Snap({fromDay: eff, endDay: endDay, permanent: permanent, coin: coin, amount: amount});
        _snaps[id].push(next);

        _addTrack(_global, next, eff);
        _addTrack(_byCoin[coin], next, eff);

        _mint(msg.sender, id);
        emit Locked(id, msg.sender, coin, amount, endDay, permanent, eff);
    }

    /// @notice Adds Chirp to an existing lock (must not be expired). Takes effect on `today + 1`.
    function addAmount(uint256 id, uint128 addChirp) external nonReentrant {
        if (_ownerOf[id] != msg.sender) revert NotOwner();
        if (addChirp == 0) revert ZeroAmount();
        uint32 today = currentDay();
        uint32 eff = today + 1;

        Snap memory old = _latest(id);
        if (!old.permanent && old.endDay <= eff) revert BadDuration();

        _stepAll(_global, today);
        _stepCoin(old.coin, today);

        if (!chirp.transferFrom(msg.sender, address(this), addChirp)) revert TransferFailed();
        totalLocked += addChirp;

        Snap memory next = Snap({
            fromDay: eff,
            endDay: old.endDay,
            permanent: old.permanent,
            coin: old.coin,
            amount: old.amount + addChirp
        });
        _applyMutation(id, old, next, eff);
        emit Added(id, addChirp, next.amount, eff);
    }

    /// @notice Extends a fixed-term lock's `endDay` forward (at least MIN_DAYS from `today + 1`, at most MAX_DAYS).
    function extend(uint256 id, uint32 newEndDay) external nonReentrant {
        if (_ownerOf[id] != msg.sender) revert NotOwner();
        uint32 today = currentDay();
        uint32 eff = today + 1;

        Snap memory old = _latest(id);
        if (old.permanent) revert IsPermanent();
        if (newEndDay <= old.endDay || newEndDay < eff + MIN_DAYS || newEndDay > eff + MAX_DAYS) revert BadDuration();

        _stepAll(_global, today);
        _stepCoin(old.coin, today);

        Snap memory next = Snap({
            fromDay: eff,
            endDay: newEndDay,
            permanent: false,
            coin: old.coin,
            amount: old.amount
        });
        _applyMutation(id, old, next, eff);
        emit Extended(id, newEndDay, eff);
    }

    /// @notice Toggles permanent max-lock. Turning on pins weight at 100%; turning off starts a 365-day countdown from `today + 1`.
    function setPermanent(uint256 id, bool on) external nonReentrant {
        if (_ownerOf[id] != msg.sender) revert NotOwner();
        uint32 today = currentDay();
        uint32 eff = today + 1;

        Snap memory old = _latest(id);
        if (old.permanent == on) return;
        uint32 newEnd = on ? 0 : eff + MAX_DAYS;

        _stepAll(_global, today);
        _stepCoin(old.coin, today);

        Snap memory next = Snap({
            fromDay: eff,
            endDay: newEnd,
            permanent: on,
            coin: old.coin,
            amount: old.amount
        });
        _applyMutation(id, old, next, eff);
        emit PermanentSet(id, on, newEnd, eff);
    }

    /// @notice Redirects a lock's weight to `newCoin` starting `today + 1` (natural 24h anti-hopping cooldown).
    function switchCoin(uint256 id, address newCoin) external nonReentrant {
        if (_ownerOf[id] != msg.sender) revert NotOwner();
        _requireRegistered(newCoin);
        uint32 today = currentDay();
        uint32 eff = today + 1;

        Snap memory old = _latest(id);
        if (old.coin == newCoin) revert SameCoin();
        if (!old.permanent && old.endDay <= eff) revert BadDuration();

        _stepAll(_global, today);
        _stepCoin(old.coin, today);
        _stepCoin(newCoin, today);

        Snap memory next = Snap({
            fromDay: eff,
            endDay: old.endDay,
            permanent: old.permanent,
            coin: newCoin,
            amount: old.amount
        });
        _applyMutation(id, old, next, eff);
        emit CoinSwitched(id, old.coin, newCoin, eff);
    }

    /// @notice Burns an expired veNFT and returns 100% of the locked Chirp. Zero external dependencies.
    function withdraw(uint256 id) external nonReentrant {
        if (_ownerOf[id] != msg.sender) revert NotOwner();
        uint32 today = currentDay();
        Snap memory old = _latest(id);
        if (old.permanent || today < old.endDay) revert StillLocked();

        _stepAll(_global, today);
        _stepCoin(old.coin, today);

        uint128 amt = old.amount;
        lastOwner[id] = msg.sender;
        _burn(id);
        totalLocked -= amt;

        if (!chirp.transfer(msg.sender, amt)) revert TransferFailed();
        emit Withdrawn(id, msg.sender, amt);
    }

    // ---- bounded lazy checkpoints (so multi-year idle gaps can always step in chunks) ----

    function checkpoint(uint32 maxDays) external returns (uint32) {
        uint32 today = currentDay();
        uint32 gap = today > _global.lastDay ? today - _global.lastDay : 0;
        uint32 target = maxDays >= gap ? today : _global.lastDay + maxDays;
        _stepAll(_global, target);
        return _global.lastDay;
    }

    function checkpointCoin(address coin, uint32 maxDays) external returns (uint32) {
        uint32 today = currentDay();
        Track storage tr = _byCoin[coin];
        if (tr.lastDay == 0) {
            tr.lastDay = today;
            return today;
        }
        uint32 gap = today > tr.lastDay ? today - tr.lastDay : 0;
        uint32 target = maxDays >= gap ? today : tr.lastDay + maxDays;
        _stepAll(tr, target);
        return tr.lastDay;
    }

    // ---- views & CollectiveSilo readers ----

    function snapCount(uint256 id) external view returns (uint256) {
        return _snaps[id].length;
    }

    function latestSnap(uint256 id) external view returns (Snap memory) {
        return _latest(id);
    }

    /// @notice Steps global track to `today` and returns exact total weight on day `day <= today`.
    function totalWeightAt(uint32 day) external returns (uint256) {
        uint32 today = currentDay();
        if (day > today) revert FutureDay();
        _stepAll(_global, today);
        return _global.weightAt[day];
    }

    /// @notice Steps coin track to `today` and returns exact coin weight on day `day <= today`.
    function coinWeightAt(address coin, uint32 day) external returns (uint256) {
        uint32 today = currentDay();
        if (day > today) revert FutureDay();
        _stepCoin(coin, today);
        return _byCoin[coin].weightAt[day];
    }

    /// @notice Pure view of total weight on any day already stepped (<= lastDay).
    function viewTotalWeightAt(uint32 day) external view returns (uint256) {
        if (day > _global.lastDay) revert NotStepped();
        return _global.weightAt[day];
    }

    /// @notice Pure view of coin weight on any day already stepped (<= coin.lastDay).
    function viewCoinWeightAt(address coin, uint32 day) external view returns (uint256) {
        Track storage tr = _byCoin[coin];
        if (tr.lastDay == 0 || day > tr.lastDay) return 0;
        return tr.weightAt[day];
    }

    /// @notice Read-only preview of global weight on `day`, stepping in memory when `day > lastDay` (e.g. after 00:00 UTC).
    function previewTotalWeightAt(uint32 day) external view returns (uint256) {
        return _previewWeight(_global, day);
    }

    /// @notice Read-only preview of coin weight on `day`, stepping in memory when `day > lastDay`.
    function previewCoinWeightAt(address coin, uint32 day) external view returns (uint256) {
        return _previewWeight(_byCoin[coin], day);
    }

    function _previewWeight(Track storage tr, uint32 day) internal view returns (uint256) {
        uint32 d = tr.lastDay;
        if (d == 0) return 0;
        if (day <= d) return tr.weightAt[day];
        uint256 perm = tr.perm;
        uint256 bias = tr.bias;
        uint256 slope = tr.slope;
        while (d < day) {
            unchecked {
                d += 1;
            }
            bias -= slope;
            int256 pd = tr.permDelta[d];
            if (pd != 0) perm = uint256(int256(perm) + pd);
            int256 bd = tr.biasDelta[d];
            if (bd != 0) bias = uint256(int256(bias) + bd);
            int256 sd = tr.slopeDelta[d];
            if (sd != 0) slope = uint256(int256(slope) + sd);
        }
        return perm + bias / uint256(MAX_DAYS);
    }

    /// @notice Returns the coin and exact weight of `lockId` on historical/current day `day`.
    function lockStateAt(uint256 id, uint32 day) public view returns (address coin, uint256 weight) {
        Snap[] storage arr = _snaps[id];
        uint256 n = arr.length;
        if (n == 0 || day < arr[0].fromDay) return (address(0), 0);
        // Binary search for the last snap with fromDay <= day.
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) >> 1;
            if (arr[mid].fromDay <= day) lo = mid;
            else hi = mid - 1;
        }
        Snap storage s = arr[lo];
        coin = s.coin;
        if (s.amount == 0) return (coin, 0);
        if (s.permanent) return (coin, uint256(s.amount));
        if (day >= s.endDay) return (coin, 0);
        return (coin, uint256(s.amount) * uint256(s.endDay - day) / uint256(MAX_DAYS));
    }

    function firstDayOf(uint256 id) external view returns (uint32) {
        Snap[] storage arr = _snaps[id];
        return arr.length == 0 ? 0 : arr[0].fromDay;
    }

    // ---- internals ----

    function _latest(uint256 id) internal view returns (Snap memory) {
        Snap[] storage arr = _snaps[id];
        return arr[arr.length - 1];
    }

    function _applyMutation(uint256 id, Snap memory old, Snap memory next, uint32 eff) internal {
        _removeTrack(_global, old, eff);
        _addTrack(_global, next, eff);
        _removeTrack(_byCoin[old.coin], old, eff);
        _addTrack(_byCoin[next.coin], next, eff);

        Snap[] storage arr = _snaps[id];
        if (arr[arr.length - 1].fromDay == eff) {
            arr[arr.length - 1] = next;
        } else {
            arr.push(next);
        }
    }

    function _addTrack(Track storage tr, Snap memory s, uint32 eff) internal {
        if (s.amount == 0) return;
        if (s.permanent) {
            tr.permDelta[eff] += int256(uint256(s.amount));
        } else if (s.endDay > eff) {
            uint256 amt = uint256(s.amount);
            tr.biasDelta[eff] += int256(amt * uint256(s.endDay - eff));
            tr.slopeDelta[eff] += int256(amt);
            tr.slopeDelta[s.endDay] -= int256(amt);
        }
    }

    function _removeTrack(Track storage tr, Snap memory s, uint32 eff) internal {
        if (s.amount == 0) return;
        if (s.permanent) {
            tr.permDelta[eff] -= int256(uint256(s.amount));
        } else if (s.endDay > eff) {
            uint256 amt = uint256(s.amount);
            tr.biasDelta[eff] -= int256(amt * uint256(s.endDay - eff));
            tr.slopeDelta[eff] -= int256(amt);
            tr.slopeDelta[s.endDay] += int256(amt);
        }
    }

    function _stepCoin(address coin, uint32 target) internal {
        Track storage tr = _byCoin[coin];
        if (tr.lastDay == 0) {
            tr.lastDay = target;
            return;
        }
        _stepAll(tr, target);
    }

    function _stepAll(Track storage tr, uint32 target) internal {
        uint32 d = tr.lastDay;
        if (d >= target) return;
        uint256 perm = tr.perm;
        uint256 bias = tr.bias;
        uint256 slope = tr.slope;
        while (d < target) {
            unchecked {
                d += 1;
            }
            bias -= slope;
            int256 pd = tr.permDelta[d];
            if (pd != 0) perm = uint256(int256(perm) + pd);
            int256 bd = tr.biasDelta[d];
            if (bd != 0) bias = uint256(int256(bias) + bd);
            int256 sd = tr.slopeDelta[d];
            if (sd != 0) slope = uint256(int256(slope) + sd);
            tr.weightAt[d] = perm + bias / uint256(MAX_DAYS);
        }
        tr.lastDay = d;
        tr.perm = perm;
        tr.bias = bias;
        tr.slope = slope;
    }

    function _requireRegistered(address coin) internal view {
        if (coin == address(0) || coin == WETH) revert UnknownCoin();
        bool coinIs0 = coin < WETH;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(coinIs0 ? coin : WETH),
            currency1: Currency.wrap(coinIs0 ? WETH : coin),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        if (hook.coin(key.toId()).vault == address(0)) revert UnknownCoin();
    }
}
