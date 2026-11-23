// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Chirp} from "./Chirp.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPintoSilo} from "./interfaces/IPintoSilo.sol";
import {IPintoField} from "./interfaces/IPintoField.sol";
import {IPeg} from "./interfaces/IPeg.sol";

/// @notice Holds the Chirp shelf and the Pinto behind it.
///         Buyers' Pinto is silo-deposited. A sell withdraws that slice in the same transaction.
///         A buy pays 1% until the launch clock starts. For the next ten minutes the buy fee
///         starts at 90% and falls in a straight line to 1%. After that it is 1% and cannot change.
///         Sells are always 1%. The toll buys no Chirp, and the full Pinto still joins the price.
///         Nobody can pause. Nobody can pull the shelf.
///         Not a proxy. No delegatecall. No path that adds a withdraw later.
contract ChirpBook {
    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant TOLL_START_BPS = 9000;
    uint256 public constant TOLL_WINDOW = 10 minutes;
    uint8 public constant EXTERNAL_MODE = 0;
    uint256 private constant MAX_HARVEST_SCAN = 32;
    /// @notice Pinto pays this wallet the referrer's pods. The address Silica wrote down.
    address public constant REFERRER = 0x0dB14dc82CBB0ce820F65c9796E0bC9E19eF08bf;

    Chirp public immutable chirp;
    address public immutable pinto;
    IPintoSilo public immutable silo;
    IPintoField public immutable field;
    IPeg public immutable peg;
    address public immutable factory;

    address public trader;
    bool public opened;
    bool private locked;
    /// @notice Zero until the factory starts it, after the launch buy. The schedule has no setter.
    uint256 public tollStart;

    /// @notice Opening cap in raw Pinto (6 decimals). Real Pinto starts at zero.
    uint256 public virtualPinto;
    uint256 public pintoInCurve;
    uint256 public chirpReserve;
    uint256 public openingChirp;
    /// @notice Silo Pinto too small to buy a Chirp, or left when the shelf is empty. Not spendable by a sell.
    uint256 public unswept;
    uint256 public siloPinto;
    /// @notice Liquid Pinto waiting to be sown. Not part of the price.
    uint256 public sowPile;

    struct Plot {
        uint256 fieldId;
        uint256 index;
        uint256 pods;
    }

    struct SellQuote {
        uint256 gross;
        uint256 paid;
        uint256 sowCut;
        uint256 leave;
        uint256 newP;
        uint256 newC;
    }

    Plot[] private _plots;
    int96[] private _stems;
    mapping(int96 => uint256) public stemAmount;

    event Bought(address indexed payer, address indexed recipient, uint256 pintoIn, uint256 chirpOut);
    event Sold(address indexed payer, uint256 chirpIn, uint256 pintoOut);
    event Sowed(uint256 indexed fieldId, uint256 index, uint256 pintoAmount, uint256 pods);
    event Harvested(uint256 beans);

    error OnlyFactory();
    error OnlyTrader();
    error ZeroAddress();
    error NotOpen();
    error Opened();
    error NoTrader();
    error TraderSet();
    error Locked();
    error ZeroIn();
    error ZeroOut();
    error PullFailed();
    error ShortPull();
    error ShortDeposit();
    error ShortWithdraw();
    error ShortPlant();
    error ShortSow();
    error ShortHarvest();
    error SellTooBig();
    error AbovePeg();
    error BelowMaxTemperature();
    error SowAmount();
    error NotEnoughSoil();
    error ZeroPods();
    error StemShort();
    error ApproveFailed();
    error ChirpMissing();
    error PintoMissing();
    error ClockStarted();

    modifier lock() {
        if (locked) revert Locked();
        locked = true;
        _;
        locked = false;
    }

    constructor(Chirp chirp_, address pinto_, address silo_, address field_, address peg_) {
        if (
            address(chirp_) == address(0) || pinto_ == address(0) || silo_ == address(0) || field_ == address(0)
                || peg_ == address(0)
        ) revert ZeroAddress();
        chirp = chirp_;
        pinto = pinto_;
        silo = IPintoSilo(silo_);
        field = IPintoField(field_);
        peg = IPeg(peg_);
        factory = msg.sender;
    }

    function setTrader(address next) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (trader != address(0)) revert TraderSet();
        if (next == address(0)) revert ZeroAddress();
        trader = next;
    }

    /// @param virtualPintoRaw Opening cap in raw Pinto. The paid Pinto side still starts empty.
    function open(uint256 virtualPintoRaw) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (opened) revert Opened();
        if (trader == address(0)) revert NoTrader();
        if (virtualPintoRaw == 0) revert ZeroIn();
        uint256 bal = chirp.balanceOf(address(this));
        if (bal != chirp.SUPPLY()) revert ChirpMissing();
        if (virtualPintoRaw > type(uint256).max / bal) revert ZeroIn();
        virtualPinto = virtualPintoRaw;
        chirpReserve = bal;
        openingChirp = bal;
        opened = true;
    }

    /// @notice Starts the ten-minute buy toll. The factory calls this after its own 1% buy.
    function startClock() external {
        if (msg.sender != factory) revert OnlyFactory();
        if (!opened) revert NotOpen();
        if (tollStart != 0) revert ClockStarted();
        tollStart = block.timestamp;
    }

    /// @notice Buy fee in bps. Sells do not use this. 1% while the clock is off, so the launch buy pays 1%.
    function buyFeeBps() public view returns (uint256) {
        uint256 start = tollStart;
        if (start == 0) return FEE_BPS;
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= TOLL_WINDOW) return FEE_BPS;
        return TOLL_START_BPS - (TOLL_START_BPS - FEE_BPS) * elapsed / TOLL_WINDOW;
    }

    function buy(address payer, uint256 pintoIn, address recipient) external lock returns (uint256 chirpOut) {
        if (msg.sender != trader) revert OnlyTrader();
        if (!opened) revert NotOpen();
        if (payer == address(0) || recipient == address(0) || payer == address(this) || recipient == address(this)) {
            revert ZeroAddress();
        }
        if (pintoIn == 0) revert ZeroIn();
        _sync();
        _shelve(_notePlant());

        IERC20 token = IERC20(pinto);
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(payer, address(this), pintoIn)) revert PullFailed();
        if (token.balanceOf(address(this)) - before != pintoIn) revert ShortPull();

        uint256 traded = pintoIn * (BPS - buyFeeBps()) / BPS;
        chirpOut = _chirpOut(traded);
        if (chirpOut == 0) revert ZeroOut();

        chirpReserve -= chirpOut;
        pintoInCurve += pintoIn;
        _deposit(pintoIn);
        if (!chirp.transfer(recipient, chirpOut)) revert PullFailed();
        emit Bought(payer, recipient, pintoIn, chirpOut);
    }

    function sell(address payer, uint256 chirpIn, address recipient) external lock returns (uint256 paid) {
        if (msg.sender != trader) revert OnlyTrader();
        if (!opened) revert NotOpen();
        if (payer == address(0) || recipient == address(0) || payer == address(this)) revert ZeroAddress();
        if (chirpIn == 0) revert ZeroIn();
        _sync();
        _shelve(_notePlant());

        uint256 before = chirp.balanceOf(address(this));
        if (!chirp.transferFrom(payer, address(this), chirpIn)) revert PullFailed();
        if (chirp.balanceOf(address(this)) - before != chirpIn) revert ShortPull();

        SellQuote memory q = _quoteSell(chirpIn);
        pintoInCurve = q.newP;
        chirpReserve = q.newC;
        sowPile += q.sowCut;
        _withdraw(q.leave);
        if (q.paid != 0 && !IERC20(pinto).transfer(recipient, q.paid)) revert PullFailed();
        emit Sold(payer, chirpIn, q.paid);
        return q.paid;
    }

    function claim() external lock {
        if (!opened) revert NotOpen();
        _sync();
        _shelve(_notePlant());
    }

    /// @notice Sows `amount` of the pile. Pinto's friend bonus goes to REFERRER.
    ///         A valid friend adds Pinto's bonus plot for this book. The friend's own bonus
    ///         stays on their account. The extra pods spend no Pinto. A referral that reverts
    ///         still sows the plain plot.
    function sow(uint256 amount, uint256 minTemperature) external lock {
        if (!opened) revert NotOpen();
        _sync();
        _shelve(_notePlant());
        if (!peg.belowPeg()) revert AbovePeg();
        if (amount == 0 || amount > sowPile) revert SowAmount();
        if (amount > field.totalSoil()) revert NotEnoughSoil();
        // The field also refuses a minimum above the live temperature. Anyone may call this.
        uint256 cap = field.maxTemperature();
        if (minTemperature < cap || field.temperature() < cap) revert BelowMaxTemperature();

        uint256 fieldId = field.activeField();
        uint256 index = field.podIndex(fieldId);
        (uint256 pods, uint256 refereePods) = _sowField(amount, minTemperature);
        if (pods == 0) revert ZeroPods();

        sowPile -= amount;
        _plots.push(Plot({fieldId: fieldId, index: index, pods: pods}));
        _noteBonus(fieldId, index, pods, refereePods);
        emit Sowed(fieldId, index, amount, pods);
    }

    /// @dev minSoil equals the Pinto spent, same as a plain sow. The referral call is attempted
    ///      first. A revert there rolls its own burn back, and the plain sow runs instead.
    function _sowField(uint256 amount, uint256 minTemperature)
        internal
        returns (uint256 pods, uint256 refereePods)
    {
        IERC20 token = IERC20(pinto);
        uint256 before = token.balanceOf(address(this));
        if (!token.approve(address(field), amount)) revert ApproveFailed();
        try field.sowWithReferral(amount, minTemperature, amount, EXTERNAL_MODE, REFERRER) returns (
            uint256 got, uint256, uint256 bonus
        ) {
            pods = got;
            refereePods = bonus;
        } catch {
            pods = field.sow(amount, minTemperature, EXTERNAL_MODE);
        }
        if (!token.approve(address(field), 0)) revert ApproveFailed();
        if (before - token.balanceOf(address(this)) != amount) revert ShortSow();
    }

    /// @dev Pinto places the book's bonus immediately after the main plot. Record it only when
    ///      that plot is exactly the size Pinto returned. A miss or a reverting read drops the
    ///      bonus and keeps the main plot, so one bad bonus cannot stall a later harvest.
    function _noteBonus(uint256 fieldId, uint256 index, uint256 pods, uint256 refereePods) internal {
        if (refereePods == 0) return;
        uint256 bonusIndex = index + pods;
        try field.plot(address(this), fieldId, bonusIndex) returns (uint256 stored) {
            if (stored == refereePods) {
                _plots.push(Plot({fieldId: fieldId, index: bonusIndex, pods: refereePods}));
            }
        } catch {}
    }

    /// @notice Harvests up to 32 fully mature plots, scanning from plot `start`. A plot still owed
    ///         pods is left alone. Unripe plots ahead of ripe ones (many small sows) cannot stall
    ///         harvest: pass a later `start` to skip past them. See `plotAt`.
    function harvest(uint256 start) external lock {
        if (!opened) revert NotOpen();
        _sync();
        _shelve(_notePlant());

        uint256 beans;
        uint256 seen;
        uint256 i = start;
        IERC20 token = IERC20(pinto);
        while (i < _plots.length && seen < MAX_HARVEST_SCAN) {
            seen++;
            Plot memory plot = _plots[i];
            if (plot.index + plot.pods > field.harvestableIndex(plot.fieldId)) {
                i++;
                continue;
            }
            uint256[] memory ids = new uint256[](1);
            ids[0] = plot.index;
            uint256 before = token.balanceOf(address(this));
            uint256 reported = field.harvest(plot.fieldId, ids, EXTERNAL_MODE);
            uint256 got = token.balanceOf(address(this)) - before;
            // 1 pod harvests as 1 Pinto. A short pay must not delete the plot.
            if (got != reported || got != plot.pods) revert ShortHarvest();
            beans += got;
            _plots[i] = _plots[_plots.length - 1];
            _plots.pop();
        }
        if (beans == 0) return;
        _deposit(beans);
        _shelve(beans);
        emit Harvested(beans);
    }

    function pricePintoPerChirp() external view returns (uint256) {
        if (chirpReserve == 0) return 0;
        return (virtualPinto + pintoInCurve) * 1e18 / chirpReserve;
    }

    function openingPrice() external view returns (uint256) {
        if (openingChirp == 0) return 0;
        return virtualPinto * 1e18 / openingChirp;
    }

    function plotCount() external view returns (uint256) {
        return _plots.length;
    }

    function plotAt(uint256 i) external view returns (uint256 fieldId, uint256 index, uint256 pods) {
        Plot memory plot = _plots[i];
        return (plot.fieldId, plot.index, plot.pods);
    }

    function siloAccounted() external view returns (uint256 sum) {
        uint256 n = _stems.length;
        for (uint256 i; i < n; i++) {
            sum += stemAmount[_stems[i]];
        }
    }

    /// @dev Donated Chirp joins the reserve. Donated Pinto joins the sow pile, not the price.
    function _sync() internal {
        IERC20 token = IERC20(pinto);
        uint256 loose = token.balanceOf(address(this));
        if (loose < sowPile) revert PintoMissing();
        sowPile = loose;
        uint256 bal = chirp.balanceOf(address(this));
        if (bal < chirpReserve) revert ChirpMissing();
        chirpReserve = bal;
    }

    /// @dev Yield buys the shelf at the full amount. Dust that cannot buy a Chirp waits in unswept.
    function _shelve(uint256 amount) internal {
        uint256 pile = unswept + amount;
        unswept = 0;
        _buyback(pile);
    }

    /// @dev Yield buys the shelf at the full amount. The 1% trade fee is not charged.
    function _buyback(uint256 amount) internal {
        if (amount == 0) return;
        uint256 out = _chirpOut(amount);
        if (out == 0) {
            if (chirpReserve == 0) unswept += amount;
            else pintoInCurve += amount;
            return;
        }
        chirpReserve -= out;
        pintoInCurve += amount;
        chirp.burn(out);
        emit Bought(address(this), address(0), amount, out);
    }

    function _chirpOut(uint256 traded) internal view returns (uint256) {
        if (traded == 0 || chirpReserve == 0) return 0;
        return chirpReserve * traded / (virtualPinto + pintoInCurve + traded);
    }

    function _quoteSell(uint256 chirpIn) internal view returns (SellQuote memory q) {
        uint256 c = chirpReserve;
        uint256 p = pintoInCurve;
        q.gross = (virtualPinto + p) * chirpIn / (c + chirpIn);
        if (q.gross == 0) revert ZeroOut();
        // The virtual Pinto is not cash. A quote the silo cannot pay is refused whole.
        if (q.gross > p) revert SellTooBig();
        q.paid = q.gross * (BPS - FEE_BPS) / BPS;
        uint256 fee = q.gross - q.paid;
        q.sowCut = fee / 2;
        uint256 stay = fee - q.sowCut;
        q.leave = q.gross - stay;
        q.newP = p - q.leave;
        q.newC = c + chirpIn;
    }

    function _notePlant() internal returns (uint256) {
        (uint256 beans, int96 stem) = silo.plant();
        if (beans == 0) return 0;
        uint256 prev = stemAmount[stem];
        (uint256 dep,) = silo.getDeposit(address(this), pinto, stem);
        if (prev > dep || dep - prev < beans) revert ShortPlant();
        _addStem(stem, beans);
        siloPinto += beans;
        return beans;
    }

    function _deposit(uint256 amount) internal {
        if (amount == 0) return;
        IERC20 token = IERC20(pinto);
        uint256 before = token.balanceOf(address(this));
        if (!token.approve(address(silo), amount)) revert ApproveFailed();
        (,, int96 stem) = silo.deposit(pinto, amount, EXTERNAL_MODE);
        if (!token.approve(address(silo), 0)) revert ApproveFailed();
        uint256 pulled = before - token.balanceOf(address(this));
        if (pulled != amount) revert ShortDeposit();
        uint256 prev = stemAmount[stem];
        (uint256 dep,) = silo.getDeposit(address(this), pinto, stem);
        if (prev > dep || dep - prev < pulled) revert ShortDeposit();
        _addStem(stem, pulled);
        siloPinto += pulled;
    }

    /// @dev LIFO. Germinating stems are withdrawn too. Only `amount` leaves, so unswept yield stays deposited.
    function _withdraw(uint256 amount) internal {
        if (amount == 0) return;
        uint256 left = amount;
        IERC20 token = IERC20(pinto);
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
            silo.withdrawDeposit(pinto, stem, take, EXTERNAL_MODE);
            have -= take;
            stemAmount[stem] = have;
            if (have == 0) _stems.pop();
            left -= take;
        }
        if (token.balanceOf(address(this)) - before != amount) revert ShortWithdraw();
        siloPinto -= amount;
    }

    function _addStem(int96 stem, uint256 amount) internal {
        if (amount == 0) return;
        if (stemAmount[stem] == 0) _stems.push(stem);
        stemAmount[stem] += amount;
    }
}
