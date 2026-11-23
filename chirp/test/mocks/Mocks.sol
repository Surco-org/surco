// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPintoSilo} from "../../src/interfaces/IPintoSilo.sol";
import {IPintoField} from "../../src/interfaces/IPintoField.sol";
import {IPeg} from "../../src/interfaces/IPeg.sol";

contract MockPinto {
    string public constant name = "Pinto";
    string public constant symbol = "PINTO";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockSilo is IPintoSilo {
    MockPinto public pinto;
    address public book;
    bool public reenter;
    bool public skipCredit;
    bool public shortPlant;
    uint256 public shortBy;
    uint256 public shortWithdraw;
    int96 public nextStem = 1;
    int96 public germ;
    int96 public lastWithdrawStem;

    mapping(address => mapping(int96 => uint256)) public deposits;
    uint256 public plantBeans;
    int96 public plantStem = 9;

    constructor(MockPinto pinto_) {
        pinto = pinto_;
    }

    function setBook(address book_) external {
        book = book_;
    }

    function setNextStem(int96 stem) external {
        nextStem = stem;
    }

    function setGerm(int96 stem) external {
        germ = stem;
    }

    function setShortBy(uint256 amount) external {
        shortBy = amount;
    }

    function setShortWithdraw(uint256 amount) external {
        shortWithdraw = amount;
    }

    function setPlant(uint256 beans, int96 stem) external {
        plantBeans = beans;
        plantStem = stem;
    }

    function setReenter(bool on) external {
        reenter = on;
    }

    function setSkipCredit(bool on) external {
        skipCredit = on;
    }

    function setShortPlant(bool on) external {
        shortPlant = on;
    }

    function deposit(address, uint256 amount, uint8) external returns (uint256, uint256, int96) {
        if (reenter) {
            (bool ok, bytes memory data) = book.call(abi.encodeWithSignature("claim()"));
            if (!ok) assembly {
                revert(add(data, 32), mload(data))
            }
        }
        uint256 pull = amount > shortBy ? amount - shortBy : 0;
        if (pull != 0) pinto.transferFrom(msg.sender, address(this), pull);
        int96 stem = nextStem;
        if (!skipCredit) deposits[msg.sender][stem] += pull;
        return (pull, pull, stem);
    }

    function withdrawDeposit(address, int96 stem, uint256 amount, uint8) external {
        uint256 have = deposits[msg.sender][stem];
        require(have >= amount, "deposit");
        deposits[msg.sender][stem] = have - amount;
        lastWithdrawStem = stem;
        uint256 pay = amount > shortWithdraw ? amount - shortWithdraw : 0;
        if (pay != 0) pinto.transfer(msg.sender, pay);
    }

    function plant() external returns (uint256 beans, int96 stem) {
        if (reenter) {
            (bool ok, bytes memory data) = book.call(abi.encodeWithSignature("claim()"));
            if (!ok) assembly {
                revert(add(data, 32), mload(data))
            }
        }
        beans = plantBeans;
        stem = plantStem;
        plantBeans = 0;
        if (beans != 0) deposits[msg.sender][stem] += shortPlant ? beans - 1 : beans;
    }

    function getGerminatingStem(address) external view returns (int96) {
        return germ;
    }

    function stemTipForToken(address) external pure returns (int96) {
        return 0;
    }

    function getDeposit(address account, address, int96 stem) external view returns (uint256 amount, uint256 bdv) {
        amount = deposits[account][stem];
        bdv = amount;
    }
}

contract MockField is IPintoField {
    MockPinto public pinto;
    uint256 public soil = 1_000_000_000e6;
    uint256 public temp = 100_000_000;
    /// @notice Unset cap refuses every practical sow. Tests that sow set this down to the temperature.
    uint256 public maxTemp = type(uint256).max;
    uint256 public active = 0;
    uint256 public harvests;
    uint256 public lastMinTemp;
    uint256 public lastPods;
    address public lastReferrer;
    bool public shortHarvest;
    bool public referralReverts;
    bool public bonusMismatch;

    mapping(uint256 => uint256) public indexOf;
    mapping(uint256 => uint256) public matureAt;
    mapping(uint256 => mapping(uint256 => uint256)) public plotsOf;
    mapping(address => bool) public eligible;

    constructor(MockPinto pinto_) {
        pinto = pinto_;
        indexOf[0] = 46_422_690_411_282;
    }

    function setSoil(uint256 soil_) external {
        soil = soil_;
    }

    function setTemp(uint256 temp_) external {
        temp = temp_;
    }

    function setMaxTemp(uint256 maxTemp_) external {
        maxTemp = maxTemp_;
    }

    function setShortHarvest(bool on) external {
        shortHarvest = on;
    }

    function setMatureAt(uint256 fieldId, uint256 at) external {
        matureAt[fieldId] = at;
    }

    function setEligible(address account, bool on) external {
        eligible[account] = on;
    }

    function setReferralReverts(bool on) external {
        referralReverts = on;
    }

    function setBonusMismatch(bool on) external {
        bonusMismatch = on;
    }

    function totalSoil() external view returns (uint256) {
        return soil;
    }

    function temperature() external view returns (uint256) {
        return temp;
    }

    function maxTemperature() external view returns (uint256) {
        return maxTemp;
    }

    function activeField() external view returns (uint256) {
        return active;
    }

    function podIndex(uint256 fieldId) external view returns (uint256) {
        return indexOf[fieldId];
    }

    function harvestableIndex(uint256 fieldId) external view returns (uint256) {
        return matureAt[fieldId];
    }

    function plot(address, uint256 fieldId, uint256 index) external view returns (uint256) {
        return plotsOf[fieldId][index];
    }

    function sow(uint256 amount, uint256 minTemperature, uint8) external returns (uint256 pods) {
        pods = _sow(amount, minTemperature);
    }

    /// @dev Referee bonus is 5% of the Pinto, minted as a second plot with no soil and no Pinto.
    ///      The friend's 10% is not stored here. Chirp never records that plot.
    function sowWithReferral(uint256 amount, uint256 minTemperature, uint256 minSoil, uint8, address referrer)
        external
        returns (uint256 pods, uint256 referrerPods, uint256 refereePods)
    {
        if (referralReverts) revert("referral");
        lastReferrer = referrer;
        require(amount >= minSoil, "minSoil");
        pods = _sow(amount, minTemperature);
        if (referrer == address(0) || referrer == msg.sender || !eligible[referrer]) return (pods, 0, 0);
        uint256 bonusBeans = amount * 50_000 / 1_000_000;
        if (bonusBeans == 0) return (pods, 0, 0);
        if (bonusMismatch) return (pods, 0, 1);
        refereePods = bonusBeans + bonusBeans * temp / 1e8;
        plotsOf[active][indexOf[active]] = refereePods;
        indexOf[active] += refereePods;
        referrerPods = 0;
    }

    function _sow(uint256 amount, uint256 minTemperature) internal returns (uint256 pods) {
        lastMinTemp = minTemperature;
        require(minTemperature <= temp, "temp");
        require(amount <= soil, "soil");
        pinto.transferFrom(msg.sender, address(this), amount);
        soil -= amount;
        // 100% temperature is 100e6, and 100e6 / 1e8 == 1, so pods = amount * (1 + temp/1e8).
        pods = amount + amount * temp / 1e8;
        lastPods = pods;
        plotsOf[active][indexOf[active]] = pods;
        indexOf[active] += pods;
    }

    function harvest(uint256 fieldId, uint256[] calldata ids, uint8) external returns (uint256 beans) {
        harvests++;
        for (uint256 i; i < ids.length; i++) {
            beans += plotsOf[fieldId][ids[i]];
        }
        if (shortHarvest && beans != 0) beans -= 1;
        if (beans != 0) pinto.mint(msg.sender, beans);
    }
}

contract MockPeg is IPeg {
    bool public under = true;

    function set(bool under_) external {
        under = under_;
    }

    function belowPeg() external view returns (bool) {
        return under;
    }
}
