// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPintoConvert} from "./interfaces/IPintoConvert.sol";
import {VaultBase} from "./VaultBase.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {
    PINTO,
    PINTO_DIAMOND,
    REDEEM_FEE_BPS,
    LAMBDA_LAMBDA,
    MERGE_ABOVE_STEMS,
    MERGE_GAS
} from "./Constants.sol";

/// @notice Redeem mode. The vault's Silo Pinto backs the coin: any holder can burn coins for their share of it, less
///         REDEEM_FEE_BPS, which stays in the vault for everyone else. Silo yield is planted back in. Finished stems
///         are merged into one deposit with Pinto's Lambda -> Lambda convert, so a redemption walks few stems.
///         Unconverted WETH is not part of the share; it is converted later, for whoever still holds.
contract RedeemVault is VaultBase {
    IPintoConvert internal constant CONVERT = IPintoConvert(PINTO_DIAMOND);

    event Redeemed(address indexed holder, address indexed recipient, uint256 coins, uint256 pinto);

    error Slippage();
    error ShortMerge();
    error OnlySelf();
    error MergeGas();

    constructor(LaunchToken coin_, address safe_, address creatorPayout_, uint16 creatorBps_)
        VaultBase(coin_, safe_, creatorPayout_, creatorBps_)
    {}

    /// @notice Burns `amount` of the caller's coins and pays `recipient` their share of the Silo Pinto, less the fee.
    ///         The share is of `totalSupply` read before the burn, coins in the pool included, so buying cheap and
    ///         redeeming never pays more than the coins' share.
    function redeem(uint256 amount, uint256 minPinto, address recipient) external lock returns (uint256 out) {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 supply = coin.totalSupply();
        if (supply == 0) revert ZeroOut();
        uint256 gross = amount * siloPinto / supply;
        out = gross - (gross * REDEEM_FEE_BPS + 9_999) / 1e4; // the fee rounds up, in the vault's favour
        if (out == 0) revert ZeroOut();
        if (out < minPinto) revert Slippage();
        coin.transferFrom(msg.sender, address(this), amount);
        coin.burn(amount);
        _withdraw(out);
        if (!IERC20(PINTO).transfer(recipient, out)) revert PayFailed();
        emit Redeemed(msg.sender, recipient, amount, out);
    }

    /// @notice At peg, plants the vault's Silo yield, which stays deposited and backs the coin. Below peg there is
    ///         no yield, so it returns without calling the Silo. Anyone may call it.
    function claim() external lock {
        if (_belowPeg()) return;
        _plant();
    }

    /// @notice Merges every finished (non-germinating) stem into one deposit. Anyone may call it. With fewer than
    ///         two finished stems it does nothing. A failure reverts with its own reason (Pinto's, or ShortMerge).
    function merge() external lock {
        _merge();
    }

    /// @notice `convert()`'s merge, run as its own call so any failure in it (Pinto's revert, a changed return
    ///         tuple, a missing view, ShortMerge) rolls back atomically, Pinto's convert included, and is caught.
    /// @dev    No `lock`: only this contract may call it, from inside `convert()`, which holds the lock.
    function mergeSelf() external {
        if (msg.sender != address(this)) revert OnlySelf();
        _merge();
    }

    /// @notice Every stem the vault holds Pinto on, oldest first; `_withdraw` takes from the end.
    function stems() external view returns (int96[] memory) {
        return _stems;
    }

    function _afterConvert() internal override {
        // A merge that fails for any reason must not stop conversion: the stems stay apart, books untouched, until
        // a merge() succeeds. Running out of gas is not such a reason: the call forwards 63/64 of what is left, so
        // a caller sized by eth_estimateGas could starve the merge and have the catch swallow it. Refusing here
        // makes the estimate include MERGE_GAS.
        if (_stems.length > MERGE_ABOVE_STEMS) {
            if (gasleft() < MERGE_GAS * 64 / 63) revert MergeGas();
            try this.mergeSelf() {} catch {}
        }
    }

    /// @dev Pinto skips germinating stems itself, so they are left out of the call and the total (IPintoConvert.sol).
    function _merge() private {
        (int96[] memory from, uint256[] memory amounts, int96[] memory keep, uint256 total) = _mergeInputs();
        if (from.length < 2) return;
        (int96 toStem, uint256 fromAmount, uint256 toAmount,,) =
            CONVERT.convert(abi.encode(LAMBDA_LAMBDA, total, PINTO), from, amounts);
        if (fromAmount != total || toAmount != total) revert ShortMerge();
        _noteMerge(from, keep, toStem, total);
    }

    /// @dev Splits the stems into finished ones (with their amounts and total) and germinating ones.
    function _mergeInputs()
        private
        view
        returns (int96[] memory from, uint256[] memory amounts, int96[] memory keep, uint256 total)
    {
        int96 germinating = SILO.getGerminatingStem(PINTO);
        uint256 n = _stems.length;
        uint256 m;
        for (uint256 i; i < n; i++) {
            if (_stems[i] < germinating) m++;
        }
        from = new int96[](m);
        amounts = new uint256[](m);
        keep = new int96[](n - m);
        (uint256 f, uint256 k) = (0, 0);
        for (uint256 i; i < n; i++) {
            int96 stem = _stems[i];
            if (stem < germinating) {
                (from[f], amounts[f]) = (stem, stemAmount[stem]);
                total += amounts[f++];
            } else {
                keep[k++] = stem;
            }
        }
    }

    /// @dev Books a merge: the finished stems are emptied and `total` moves to `toStem`, which the Silo must hold.
    ///      `toStem` goes first in `_stems` (it is the oldest), so redemptions keep taking the newest deposits first
    ///      and the merged deposit's grown Stalk is burned last.
    function _noteMerge(int96[] memory from, int96[] memory keep, int96 toStem, uint256 total) private {
        for (uint256 i; i < from.length; i++) {
            stemAmount[from[i]] = 0;
        }
        // Pinto puts toStem below every germinating stem, so it cannot be one we keep; refuse if it ever is.
        if (stemAmount[toStem] != 0) revert ShortMerge();
        (uint256 dep,) = SILO.getDeposit(address(this), PINTO, toStem);
        if (dep < total) revert ShortMerge();
        stemAmount[toStem] = total;
        _stems[0] = toStem;
        for (uint256 i; i < keep.length; i++) {
            _stems[i + 1] = keep[i];
        }
        while (_stems.length > keep.length + 1) {
            _stems.pop();
        }
    }
}
