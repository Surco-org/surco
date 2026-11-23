// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPintoSilo} from "chirp/interfaces/IPintoSilo.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {FeeMath} from "./FeeMath.sol";
import {PintoRoute} from "./PintoRoute.sol";
import {WETH, PINTO, PINTO_DIAMOND, MAX_CONVERT_WETH, MAX_CREATOR_BPS} from "./Constants.sol";

/// @notice One per coin. The hook sends the coin's trade fee here in WETH. `split()` pays the platform cut to the
///         Safe and the creator share to the creator's payout address; the rest waits as `pendingPintoWeth` until
///         `convert()` routes it WETH -> cbETH -> Pinto and deposits the Pinto in Pinto's Silo, where no one can
///         take it. Anyone may call either. No owner, no pause, no upgrade.
/// @dev    The spec credits the Safe and creator shares to a ledger to be pulled, so a bad recipient cannot block
///         `convert()`. A WETH `transfer` cannot be refused by its recipient, so pushing gives the same guarantee
///         with no ledger. `split()` is a separate public function, so both get paid even while conversion reverts.
/// @dev    Invariant children must keep: WETH balance >= `pendingPintoWeth` outside a call, and every WETH above it
///         is an unsplit fee. Any WETH a child produces (e.g. BurnVault's `pintoToWeth` output) must be spent in the
///         same call, or the next `split()` pays it out as a fee. Mid-`convert()` the balance does not match the
///         books (the batch is off `pendingPintoWeth` before the router pulls it), which is why every entry point
///         that moves WETH or Silo Pinto takes `lock`.
/// @notice Pinto's SeasonGettersFacet.abovePeg(): set at each sunrise from the season's TWA deltaB, the same signal
///         that decides whether the Silo mints (so whether plant() earns). ~28k gas; ChirpPeg.belowPeg() was ~1M.
interface IPintoPeg {
    function abovePeg() external view returns (bool);
}

abstract contract VaultBase {
    uint8 internal constant EXTERNAL_MODE = 0;
    /// @dev Transient-storage slot of `lock` (keccak256("launcher.VaultBase.lock")).
    uint256 private constant LOCK_SLOT = 0xb152178c1cc6c92b29aa7fb2078a5053d1113042f9aecf05f2846c1db5458373;
    IPintoSilo internal constant SILO = IPintoSilo(PINTO_DIAMOND);

    LaunchToken public immutable coin;
    address public immutable safe;
    uint16 public immutable creatorBps;
    address public immutable factory;

    address public creatorPayout;
    /// @notice The split-off Pinto portion, in WETH, waiting for `convert()`.
    uint256 public pendingPintoWeth;
    /// @notice Pinto this vault holds in the Silo (raw, 6 decimals), summed over `stemAmount`.
    uint256 public siloPinto;

    int96[] internal _stems;
    mapping(int96 => uint256) public stemAmount;

    /// @param wethIn WETH routed to Pinto (the batch less the tip).
    event Converted(uint256 wethIn, uint256 pintoOut, uint256 tip);
    /// @param caller Whoever called `seed()`, not whoever sent the Pinto (that is in the Pinto Transfer events).
    event Seeded(address indexed caller, uint256 amount);
    event CreatorPayoutChanged(address indexed previous, address indexed next);

    error ZeroAddress();
    error CreatorBps();
    error OnlyCreator();
    error NothingPending();
    error ZeroOut();
    error PayFailed();
    error ApproveFailed();
    error ShortDeposit();
    error ShortWithdraw();
    error StemShort();
    error ShortPlant();
    error Locked();

    /// @dev Reentrancy lock in transient storage (EIP-1153). Children put it on their own entry points
    ///      (redeem, claim, merge, buyback); internal helpers such as `_split` take no lock.
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

    constructor(LaunchToken coin_, address safe_, address creatorPayout_, uint16 creatorBps_) {
        if (address(coin_) == address(0) || safe_ == address(0) || creatorPayout_ == address(0)) revert ZeroAddress();
        if (creatorBps_ > MAX_CREATOR_BPS) revert CreatorBps();
        coin = coin_;
        safe = safe_;
        creatorPayout = creatorPayout_;
        creatorBps = creatorBps_;
        factory = msg.sender;
    }

    /// @notice Splits every WETH not already set aside: platform cut to the Safe, creator share to the payout
    ///         address, the rest added to `pendingPintoWeth`. A second call with no new fee pays nothing.
    function split() external lock {
        _split();
    }

    function _split() internal {
        uint256 fresh = IERC20(WETH).balanceOf(address(this)) - pendingPintoWeth;
        if (fresh == 0) return;
        (uint256 platform, uint256 creator, uint256 pinto) = FeeMath.split(fresh, creatorBps);
        pendingPintoWeth += pinto;
        _pay(safe, platform);
        _pay(creatorPayout, creator);
    }

    /// @notice Splits, then converts up to MAX_CONVERT_WETH of the Pinto portion to Pinto in the Silo. The caller
    ///         keeps FeeMath.tip of the batch. If the price guard refuses the route the whole call reverts and the
    ///         WETH waits; `split()` alone still pays the Safe and the creator.
    function convert() external lock {
        _split();
        uint256 batch = pendingPintoWeth < MAX_CONVERT_WETH ? pendingPintoWeth : MAX_CONVERT_WETH;
        if (batch == 0) revert NothingPending();
        uint256 tip = FeeMath.tip(batch);
        uint256 wethIn = batch - tip;
        pendingPintoWeth -= batch;

        uint256 pintoOut = PintoRoute.wethToPinto(wethIn);
        if (pintoOut == 0) revert ZeroOut();
        _deposit(pintoOut);
        _pay(msg.sender, tip);
        emit Converted(wethIn, pintoOut, tip);
        _afterConvert();
    }

    /// @notice Books Pinto sent to this vault by plain transfer into its Silo backing. Anyone may call it. Redeem: it
    ///         raises every coin's redemption value. Burn: it is principal, never spent; its yield feeds buybacks.
    ///         Like any deposit it germinates for 2 seasons. Every call that moves Pinto runs under `lock` and ends
    ///         holding no free Pinto, so between calls the whole balance is what was sent in.
    function seed() external lock {
        uint256 amount = IERC20(PINTO).balanceOf(address(this));
        if (amount == 0) revert NothingPending();
        _deposit(amount);
        emit Seeded(msg.sender, amount);
    }

    /// @notice The current payout address hands the creator share to `next`. Fees split later go to `next` only.
    function setCreatorPayout(address next) external {
        if (msg.sender != creatorPayout) revert OnlyCreator();
        if (next == address(0)) revert ZeroAddress();
        creatorPayout = next;
        emit CreatorPayoutChanged(msg.sender, next);
    }

    /// @dev Runs last in `convert()`. RedeemVault merges stems here.
    function _afterConvert() internal virtual {}

    function _pay(address to, uint256 amount) private {
        if (amount != 0 && !IERC20(WETH).transfer(to, amount)) revert PayFailed();
    }

    /// @dev Chirp's ChirpBook._deposit: the Silo must pull exactly `amount` and credit it on the returned stem.
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
        _addStem(stem, pulled);
        siloPinto += pulled;
    }

    /// @dev Chirp's ChirpBook._withdraw: newest stems first, germinating ones included. Pays Pinto to this vault.
    function _withdraw(uint256 amount) internal {
        if (amount == 0) return;
        uint256 left = amount;
        IERC20 token = IERC20(PINTO);
        uint256 before = token.balanceOf(address(this));
        while (left != 0) {
            uint256 n = _stems.length;
            if (n == 0) revert StemShort();
            int96 stem = _stems[n - 1];
            uint256 have = stemAmount[stem];
            if (have == 0) {
                _stems.pop();
                continue;
            }
            uint256 take = have < left ? have : left;
            SILO.withdrawDeposit(PINTO, stem, take, EXTERNAL_MODE);
            have -= take;
            stemAmount[stem] = have;
            if (have == 0) _stems.pop();
            left -= take;
        }
        if (token.balanceOf(address(this)) - before != amount) revert ShortWithdraw();
        siloPinto -= amount;
    }

    /// @dev Plants the Silo yield and books it (Chirp's ChirpBook._notePlant): the Silo must hold the planted beans
    ///      on the returned stem.
    /// @dev Below peg as of the last sunrise. A mid-season drop below peg shows from the next sunrise on (R32).
    function _belowPeg() internal view returns (bool) {
        return !IPintoPeg(PINTO_DIAMOND).abovePeg();
    }

    function _plant() internal returns (uint256 beans, int96 stem) {
        (beans, stem) = SILO.plant();
        if (beans == 0) return (0, stem);
        uint256 prev = stemAmount[stem];
        (uint256 dep,) = SILO.getDeposit(address(this), PINTO, stem);
        if (prev > dep || dep - prev < beans) revert ShortPlant();
        _addStem(stem, beans);
        siloPinto += beans;
    }

    /// @dev Children record planted yield through this (and add it to `siloPinto`).
    function _addStem(int96 stem, uint256 amount) internal {
        if (amount == 0) return;
        if (stemAmount[stem] == 0) _stems.push(stem);
        stemAmount[stem] += amount;
    }
}
