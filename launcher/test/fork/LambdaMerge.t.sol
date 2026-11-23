// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPintoSilo} from "chirp/interfaces/IPintoSilo.sol";
import {IPintoPeg} from "../../src/VaultBase.sol";
import {IPintoConvert} from "../../src/interfaces/IPintoConvert.sol";
import {PINTO, PINTO_DIAMOND, LAMBDA_LAMBDA, SUPPLY} from "../../src/Constants.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {RedeemHarness} from "../RedeemVault.t.sol";

/// The Silo and season views the research needs; not used by the contracts.
interface IPintoViews {
    function sunrise() external payable returns (uint256);
    function season() external view returns (uint32);
    function balanceOfStalk(address account) external view returns (uint256);
    function balanceOfGerminatingStalk(address account) external view returns (uint256);
    function balanceOfGrownStalk(address account, address token) external view returns (uint256);
}

/// Lambda -> Lambda on the real Diamond. This contract is the depositor.
contract LambdaMergeForkTest is Test {
    /// Base, 2026-11-20 (Task 5's block). Pinto is below peg here.
    uint256 constant FORK_BLOCK = 60_050_000;

    IPintoSilo constant SILO = IPintoSilo(PINTO_DIAMOND);
    IPintoConvert constant CONVERT = IPintoConvert(PINTO_DIAMOND);
    IPintoViews constant VIEWS = IPintoViews(PINTO_DIAMOND);

    int96[] stems;
    uint256[] amounts;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        deal(PINTO, address(this), 10_000e6);
        IERC20(PINTO).approve(PINTO_DIAMOND, type(uint256).max);
        // Three deposits in three seasons, then two more seasons so all three have finished germinating.
        _deposit(100e6);
        _sunrise();
        _deposit(200e6);
        _sunrise();
        _deposit(300e6);
        _sunrise();
        assertGe(stems[2], SILO.getGerminatingStem(PINTO), "still germinating one season on");
        _sunrise();
        assertLt(stems[2], SILO.getGerminatingStem(PINTO), "finished two seasons on");
    }

    function _deposit(uint256 amount) internal {
        (,, int96 stem) = SILO.deposit(PINTO, amount, 0);
        stems.push(stem);
        amounts.push(amount);
    }

    /// Next hour boundary, then sunrise() with the keeper's 6M gas limit.
    function _sunrise() internal {
        uint32 before = VIEWS.season();
        vm.warp((block.timestamp / 3600 + 1) * 3600);
        vm.roll(block.number + 1800);
        VIEWS.sunrise{gas: 6_000_000}();
        assertEq(VIEWS.season(), before + 1, "season advanced");
    }

    function _stalk() internal view returns (uint256) {
        return VIEWS.balanceOfStalk(address(this)) + VIEWS.balanceOfGerminatingStalk(address(this))
            + VIEWS.balanceOfGrownStalk(address(this), PINTO);
    }

    function _merge(uint256 total) internal returns (int96 toStem, uint256 gasUsed) {
        bytes memory data = abi.encode(LAMBDA_LAMBDA, total, PINTO);
        uint256 g = gasleft();
        (toStem,,,,) = CONVERT.convert(data, stems, amounts);
        gasUsed = g - gasleft();
    }

    function test_merge_three_into_one() public {
        int96 germ = SILO.getGerminatingStem(PINTO);
        int96 tip = SILO.stemTipForToken(PINTO);
        for (uint256 i; i < 3; i++) {
            assertLt(stems[i], germ, "not germinating");
        }
        // The stem rule, computed before the convert from the source's formula.
        uint256 grown;
        for (uint256 i; i < 3; i++) {
            grown += uint256(int256(tip - stems[i])) * amounts[i];
        }
        int96 expected = tip - int96(int256(grown / 600e6));
        uint256 stalkBefore = _stalk();

        (int96 toStem, uint256 gasUsed) = _merge(600e6);

        emit log_named_uint("gas, 3-stem merge", gasUsed);
        emit log_named_int("stem tip", tip);
        emit log_named_int("merged stem", toStem);
        emit log_named_uint("stalk before", stalkBefore);
        emit log_named_uint("stalk after", _stalk());
        assertEq(toStem, expected, "stem = tip - grown / bdv");
        (uint256 amt, uint256 bdv) = SILO.getDeposit(address(this), PINTO, toStem);
        assertEq(amt, 600e6, "one deposit holds the sum");
        assertEq(bdv, 600e6, "bdv = amount");
        for (uint256 i; i < 3; i++) {
            if (stems[i] == toStem) continue;
            (amt,) = SILO.getDeposit(address(this), PINTO, stems[i]);
            assertEq(amt, 0, "old stem emptied");
        }
        assertGe(_stalk(), stalkBefore, "stalk not lower");
    }

    /// Pinto skips germinating stems: they do not count toward `amount` and are left as they were.
    function test_merge_skips_germinating() public {
        _deposit(400e6);
        int96 young = stems[3];
        assertGe(young, SILO.getGerminatingStem(PINTO), "germinating");

        // Counting the germinating deposit in `amount` reverts: it is skipped, so too little is removed.
        bytes memory all = abi.encode(LAMBDA_LAMBDA, uint256(1000e6), PINTO);
        vm.expectRevert(bytes("Convert: Not enough tokens removed."));
        CONVERT.convert(all, stems, amounts);

        // The non-germinating total merges; the germinating deposit stays.
        (int96 toStem,) = _merge(600e6);
        (uint256 amt,) = SILO.getDeposit(address(this), PINTO, toStem);
        assertEq(amt, 600e6);
        (amt,) = SILO.getDeposit(address(this), PINTO, young);
        assertEq(amt, 400e6, "germinating deposit untouched");
        assertLt(toStem, young);

        // A germinating stem alone is skipped entirely: nothing to convert.
        int96[] memory one = new int96[](1);
        uint256[] memory oneAmt = new uint256[](1);
        (one[0], oneAmt[0]) = (young, 400e6);
        vm.expectRevert(bytes("Convert: Not enough tokens removed."));
        CONVERT.convert(abi.encode(LAMBDA_LAMBDA, uint256(400e6), PINTO), one, oneAmt);
    }

    function test_merge_below_peg_no_penalty() public {
        // totalDeltaB() reads 0 in the sunrise's own block; a minute later it is back below zero.
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 30);
        assertFalse(IPintoPeg(PINTO_DIAMOND).abovePeg(), "below peg at the pinned block");
        uint256 pintoBefore = IERC20(PINTO).balanceOf(address(this));
        uint256 stalkBefore = _stalk();

        (int96 toStem,) = _merge(600e6);

        (uint256 amt, uint256 bdv) = SILO.getDeposit(address(this), PINTO, toStem);
        assertEq(amt, 600e6, "no Pinto lost");
        assertEq(bdv, 600e6, "no bdv lost");
        assertEq(IERC20(PINTO).balanceOf(address(this)), pintoBefore, "no Pinto moved");
        assertGe(_stalk(), stalkBefore, "no stalk penalty");
        // The merged deposit withdraws in full, in the same block.
        SILO.withdrawDeposit(PINTO, toStem, 600e6, 0);
        assertEq(IERC20(PINTO).balanceOf(address(this)), pintoBefore + 600e6);
    }

    /// Gas for a larger merge, to size the >3-stem trigger: 10 non-germinating stems.
    function test_merge_ten_gas() public {
        for (uint256 i; i < 7; i++) {
            _deposit(10e6);
            _sunrise();
        }
        _sunrise();
        (int96 toStem, uint256 gasUsed) = _merge(660e6);
        emit log_named_uint("gas, 10-stem merge", gasUsed);
        (uint256 amt,) = SILO.getDeposit(address(this), PINTO, toStem);
        assertEq(amt, 660e6);
    }

    /// RedeemVault's own merge() and redeem() against the real Silo: finished stems become one, the germinating
    /// one is kept, and the books match getDeposit throughout.
    function test_vault_merge_real() public {
        address alice = makeAddr("alice");
        LaunchToken coin = new LaunchToken("Coin", "COIN", "", "", address(this));
        RedeemHarness vault = new RedeemHarness(coin, makeAddr("safe"), makeAddr("creator"), 0);
        for (uint256 i = 1; i <= 3; i++) {
            deal(PINTO, address(vault), 100e6 * i);
            vault.deposit(100e6 * i);
            _sunrise();
        }
        _sunrise();
        deal(PINTO, address(vault), 400e6);
        vault.deposit(400e6); // germinating
        assertEq(vault.stems().length, 4);

        uint256 g = gasleft();
        vault.merge();
        emit log_named_uint("gas, vault merge of 3 (+1 germinating kept)", g - gasleft());

        int96[] memory s = vault.stems();
        assertEq(s.length, 2);
        uint256 sum;
        for (uint256 i; i < 2; i++) {
            (uint256 amt,) = SILO.getDeposit(address(vault), PINTO, s[i]);
            assertEq(amt, vault.stemAmount(s[i]), "books = Silo");
            sum += amt;
        }
        assertEq(vault.stemAmount(s[0]), 600e6, "merged stem first (oldest)");
        assertEq(vault.stemAmount(s[1]), 400e6, "germinating stem last (newest)");
        assertEq(sum, 1_000e6);
        assertEq(vault.siloPinto(), 1_000e6);

        // Half the supply redeems 495 Pinto: all 400 of the germinating deposit first, then 95 of the merged one,
        // so the merged deposit's grown Stalk is burned last.
        coin.approve(address(vault), SUPPLY / 2);
        g = gasleft();
        uint256 out = vault.redeem(SUPPLY / 2, 495e6, alice);
        emit log_named_uint("gas, redeem across two stems", g - gasleft());
        assertEq(out, 495e6);
        assertEq(IERC20(PINTO).balanceOf(alice), 495e6);
        (uint256 left,) = SILO.getDeposit(address(vault), PINTO, s[1]);
        assertEq(left, 0, "germinating deposit taken first");
        (left,) = SILO.getDeposit(address(vault), PINTO, s[0]);
        assertEq(left, 505e6, "merged deposit drawn last");
        assertEq(vault.siloPinto(), 505e6);
    }
}
