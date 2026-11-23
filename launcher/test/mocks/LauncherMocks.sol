// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IWell} from "../../src/interfaces/IWell.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {PINTO, CBETH_WELL_PUMP} from "../../src/Constants.sol";

// Ruling R2: unit tests place these at the Constants addresses. None has a constructor or an immutable, so
// `vm.etch(ADDR, address(new MockX()).code)` and `deployCodeTo` behave the same; every price is set afterwards
// through the setters.

abstract contract MockToken {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure virtual returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) public {
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

contract MockWETH is MockToken {
    function deposit() external payable {
        mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _move(msg.sender, address(0), amount);
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }
}

contract MockCbEth is MockToken {}

contract MockPinto is MockToken {
    function decimals() external pure override returns (uint8) {
        return 6;
    }
}

/// readInstantaneousReserves returns whatever EMA reserves were set for the well.
contract MockPump {
    mapping(address => uint256[]) internal ema;

    function setReserves(address well, uint256 pinto, uint256 cb) external {
        ema[well] = [pinto, cb];
    }

    function readInstantaneousReserves(address well, bytes memory) external view returns (uint256[] memory) {
        return ema[well];
    }
}

/// Fee-less constant-product well over [PINTO, cbETH]. Swaps move the stored reserves
/// (the spot); the EMA lives in MockPump, so a test moves spot away from it with setReserves. Pays out of its
/// own token balance: mint it the reserves it should hold.
contract MockWell {
    uint256[2] internal reserves;

    error SlippageOut(uint256 amountOut, uint256 minAmountOut);

    function setReserves(uint256 pinto, uint256 cb) external {
        reserves = [pinto, cb];
    }

    function pumps() external pure returns (IWell.Call[] memory p) {
        p = new IWell.Call[](1);
        p[0] = IWell.Call(CBETH_WELL_PUMP, "");
    }

    function getReserves() external view returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (reserves[0], reserves[1]);
    }

    function getSwapOut(address fromToken, address, uint256 amountIn) public view returns (uint256) {
        uint256 i = fromToken == PINTO ? 0 : 1;
        return reserves[1 - i] * amountIn / (reserves[i] + amountIn);
    }

    function swapFrom(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) external returns (uint256 out) {
        require(block.timestamp <= deadline, "expired");
        uint256 i = fromToken == PINTO ? 0 : 1;
        out = getSwapOut(fromToken, toToken, amountIn);
        if (out < minOut) revert SlippageOut(out, minOut);
        reserves[i] += amountIn;
        reserves[1 - i] -= out;
        IERC20(fromToken).transferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).transfer(to, out);
    }
}

/// observe() answers as if the pool sat at `tick` forever, so the TWAP mean tick is `tick`.
contract MockV3Pool {
    int24 public tick;

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory cum, uint160[] memory spl) {
        cum = new int56[](ago.length);
        spl = new uint160[](ago.length);
        for (uint256 i; i < ago.length; ++i) {
            cum[i] = -int56(tick) * int56(uint56(ago[i]));
        }
    }
}

/// Stands in for SwapRouter02 + the v3 pool's spot: out = amountIn * rate[in][out] / 1e18, set per direction.
/// Pays out of its own balance: mint it the output tokens.
contract MockSwapRouter {
    mapping(address => mapping(address => uint256)) public rate;

    function setRate(address tokenIn, address tokenOut, uint256 rateWad) external {
        rate[tokenIn][tokenOut] = rateWad;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        out = p.amountIn * rate[p.tokenIn][p.tokenOut] / 1e18;
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// Pinto Silo at PINTO_DIAMOND. Deposits land on `nextStem`; `held[account]` is the sum over every stem, which is
/// what a vault's siloPinto tally must equal. plant() credits `plantBeans` at `plantStem` (minting the Pinto).
/// The Lambda -> Lambda convert arrives with RedeemVault (Task 7).
contract MockSiloWithConvert {
    int96 public nextStem;
    uint256 public plantBeans;
    int96 public plantStem;
    mapping(address => mapping(int96 => uint256)) public deposits;
    mapping(address => uint256) public held;
    /// SeasonGettersFacet.abovePeg(): at peg unless set below.
    bool public below;

    function setBelow(bool below_) external {
        below = below_;
    }

    function abovePeg() external view returns (bool) {
        return !below;
    }

    function setNextStem(int96 stem) external {
        nextStem = stem;
    }

    function setPlant(uint256 beans, int96 stem) external {
        (plantBeans, plantStem) = (beans, stem);
    }

    /// The next deposit calls `target` with `data` first and bubbles its revert (a malicious Silo).
    address public reenterTarget;
    bytes public reenterData;

    function setReenter(address target, bytes calldata data) external {
        (reenterTarget, reenterData) = (target, data);
    }

    function deposit(address, uint256 amount, uint8) external returns (uint256, uint256, int96) {
        if (reenterTarget != address(0)) {
            (bool ok, bytes memory err) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
        }
        IERC20(PINTO).transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][nextStem] += amount;
        held[msg.sender] += amount;
        return (amount, amount, nextStem);
    }

    function withdrawDeposit(address, int96 stem, uint256 amount, uint8) external {
        require(deposits[msg.sender][stem] >= amount, "deposit");
        deposits[msg.sender][stem] -= amount;
        held[msg.sender] -= amount;
        IERC20(PINTO).transfer(msg.sender, amount);
    }

    function plant() external returns (uint256 beans, int96 stem) {
        (beans, stem) = (plantBeans, plantStem);
        plantBeans = 0;
        MockPinto(PINTO).mint(address(this), beans);
        deposits[msg.sender][stem] += beans;
        held[msg.sender] += beans;
    }

    /// Stems >= this are germinating. Unset (0), every positive stem is.
    int96 public germinatingStem;
    /// 1: convert reverts. 2: convert returns toAmount one short. 3: getGerminatingStem reverts.
    uint8 public fault;

    function setGerminatingStem(int96 stem) external {
        germinatingStem = stem;
    }

    function setFault(uint8 fault_) external {
        fault = fault_;
    }

    function getGerminatingStem(address) external view returns (int96) {
        require(fault != 3, "view gone");
        return germinatingStem;
    }

    /// Lambda -> Lambda as Pinto does it (test/fork/LambdaMerge.t.sol): germinating stems are skipped, `total` is
    /// taken in order and must be removed in full, and the merged stem is tip - grownStalk / total, rounded down,
    /// with tip = nextStem.
    function convert(bytes calldata data, int96[] calldata stems, uint256[] calldata amounts)
        external
        payable
        returns (int96 toStem, uint256, uint256, uint256, uint256)
    {
        require(fault != 1, "convert refused");
        (uint8 kind, uint256 total, address token) = abi.decode(data, (uint8, uint256, address));
        require(kind == 0 && token == PINTO, "Convert: Invalid payload");
        require(total > 0, "Convert: From amount is 0.");
        require(stems.length == amounts.length, "Convert: stems, amounts are diff lengths.");
        uint256 grown = _take(stems, amounts, total);
        toStem = nextStem - int96(int256(grown / total));
        deposits[msg.sender][toStem] += total;
        return (toStem, total, fault == 2 ? total - 1 : total, total, total);
    }

    /// Removes `total` from the non-germinating stems in order; returns the grown stalk removed.
    function _take(int96[] memory stems, uint256[] memory amounts, uint256 total) private returns (uint256 grown) {
        uint256 taken;
        for (uint256 i; i < stems.length && taken < total; i++) {
            int96 stem = stems[i];
            if (stem >= germinatingStem) continue;
            uint256 a = taken + amounts[i] >= total ? total - taken : amounts[i];
            require(deposits[msg.sender][stem] >= a, "Silo: Crate balance too low.");
            deposits[msg.sender][stem] -= a;
            grown += uint256(int256(nextStem - stem)) * a;
            taken += a;
        }
        require(taken == total, "Convert: Not enough tokens removed.");
    }

    function stemTipForToken(address) external view returns (int96) {
        return nextStem;
    }

    function getDeposit(address account, address, int96 stem) external view returns (uint256, uint256) {
        return (deposits[account][stem], deposits[account][stem]);
    }
}

