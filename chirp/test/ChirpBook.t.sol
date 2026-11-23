// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Chirp} from "../src/Chirp.sol";
import {ChirpBook} from "../src/ChirpBook.sol";
import {MockPinto, MockSilo, MockField, MockPeg} from "./mocks/Mocks.sol";

contract ChirpBookTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant VIRTUAL = 1_000_000e6;
    uint256 internal constant BUY = 100e6;

    Chirp internal chirp;
    ChirpBook internal book;
    MockPinto internal pinto;
    MockSilo internal silo;
    MockField internal field;
    MockPeg internal peg;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        pinto = new MockPinto();
        silo = new MockSilo(pinto);
        field = new MockField(pinto);
        peg = new MockPeg();
        chirp = new Chirp();
        book = new ChirpBook(chirp, address(pinto), address(silo), address(field), address(peg));
        silo.setBook(address(book));
        chirp.setBook(address(book));
        chirp.transfer(address(book), chirp.SUPPLY());
        book.setTrader(address(this));
        book.open(VIRTUAL);
        pinto.mint(address(this), 1_000_000e6);
        pinto.approve(address(book), type(uint256).max);
        chirp.approve(address(book), type(uint256).max);
    }

    function _books() internal view {
        assertEq(chirp.balanceOf(address(book)), book.chirpReserve());
        assertEq(book.siloPinto(), book.pintoInCurve() + book.unswept());
        assertEq(pinto.balanceOf(address(book)), book.sowPile());
        assertEq(book.siloAccounted(), book.siloPinto());
    }

    function test_factory_shape_on_open() public view {
        assertEq(chirp.totalSupply(), 1_000_000_000 ether);
        assertEq(chirp.balanceOf(address(this)), 0);
        assertEq(book.chirpReserve(), chirp.SUPPLY());
        assertEq(book.pintoInCurve(), 0);
        assertEq(book.openingPrice(), VIRTUAL * 1e18 / chirp.SUPPLY());
    }

    function test_no_second_mint_and_only_book_burns() public {
        (bool ok,) = address(chirp).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        vm.expectRevert(Chirp.OnlyBook.selector);
        chirp.burn(1);
        vm.expectRevert(Chirp.BookSet.selector);
        chirp.setBook(address(1));
    }

    function test_buy_100_keeps_1_in_the_price() public {
        uint256 out = book.buy(address(this), BUY, address(this));
        uint256 traded = 99e6;
        uint256 expected = chirp.SUPPLY() * traded / (VIRTUAL + traded);
        assertEq(out, expected);
        assertEq(out, 98_990_199_970_202_949_907_959);
        assertEq(book.pintoInCurve(), BUY);
        assertEq(book.siloPinto(), BUY);
        assertEq(silo.deposits(address(book), 1), BUY);
        _books();
    }

    function test_sell_quoted_at_10() public {
        book.buy(address(this), BUY, address(this));
        uint256 target = 10_000_000;
        uint256 c = book.chirpReserve();
        uint256 p = book.pintoInCurve();
        uint256 base = target * c / (VIRTUAL + p - target);
        uint256 chirpIn;
        uint256 gross;
        for (uint256 d; d < 16; d++) {
            uint256 ci = base + d;
            uint256 g = (VIRTUAL + p) * ci / (c + ci);
            if (g == target) {
                chirpIn = ci;
                gross = g;
                break;
            }
        }
        assertEq(gross, target);

        uint256 siloBefore = book.siloPinto();
        uint256 paid = book.sell(address(this), chirpIn, address(this));
        assertEq(paid, 9_900_000);
        assertEq(pinto.balanceOf(address(this)), 1_000_000e6 - BUY + 9_900_000);
        assertEq(book.sowPile(), 50_000);
        assertEq(book.pintoInCurve(), BUY - 9_950_000);
        assertEq(siloBefore - book.siloPinto(), 9_950_000);
        assertGe(book.pricePintoPerChirp(), book.openingPrice());
        _books();
    }

    function test_odd_fee_wei_stays_in_the_pile() public {
        book.buy(address(this), BUY, address(this));
        uint256 target = 100;
        uint256 c = book.chirpReserve();
        uint256 p = book.pintoInCurve();
        uint256 lo = 1;
        uint256 hi = chirp.balanceOf(address(this));
        uint256 chirpIn;
        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 g = (VIRTUAL + p) * mid / (c + mid);
            if (g < target) lo = mid + 1;
            else {
                chirpIn = mid;
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        uint256 gross = (VIRTUAL + p) * chirpIn / (c + chirpIn);
        assertEq(gross, target);
        uint256 curveBefore = book.pintoInCurve();
        uint256 paid = book.sell(address(this), chirpIn, address(this));
        assertEq(paid, 99);
        assertEq(book.sowPile(), 0);
        // fee is 1. Half rounds down, so the odd wei stays in the curve.
        assertEq(curveBefore - book.pintoInCurve(), 99);
        _books();
    }

    function test_sell_entire_bag() public {
        uint256 out = book.buy(address(this), BUY, address(this));
        uint256 paid = book.sell(address(this), out, address(this));
        assertGt(paid, 0);
        assertGe(book.pricePintoPerChirp(), book.openingPrice());
        _books();
    }

    /// @dev A buy, a sell, or a plant cannot quote more Pinto than the curve holds.
    ///      This writes the stored pile so the guard still has a test.
    function test_corrupt_pile_cannot_pay_virtual_pinto() public {
        uint256 out = book.buy(address(this), BUY, address(this));
        uint256 curve = book.pintoInCurve();
        uint256 hits;
        for (uint256 i; i < 30; i++) {
            if (uint256(vm.load(address(book), bytes32(i))) == curve) {
                vm.store(address(book), bytes32(i), bytes32(uint256(1)));
                hits++;
            }
        }
        assertGt(hits, 0);
        uint256 chirpBefore = chirp.balanceOf(address(this));
        vm.expectRevert(ChirpBook.SellTooBig.selector);
        book.sell(address(this), out, address(this));
        assertEq(chirp.balanceOf(address(this)), chirpBefore);
    }

    function test_germinating_stem_is_withdrawn() public {
        silo.setNextStem(80);
        silo.setGerm(80);
        book.buy(address(this), BUY, address(this));
        uint256 out = chirp.balanceOf(address(this));
        book.sell(address(this), out / 2, address(this));
        assertEq(silo.lastWithdrawStem(), 80);
        _books();
    }

    function test_short_deposit_reverts() public {
        silo.setShortBy(1);
        vm.expectRevert(ChirpBook.ShortDeposit.selector);
        book.buy(address(this), BUY, address(this));
        assertEq(book.pintoInCurve(), 0);
        assertEq(chirp.balanceOf(address(book)), chirp.SUPPLY());
    }

    function test_deposit_must_match_the_stem() public {
        silo.setSkipCredit(true);
        vm.expectRevert(ChirpBook.ShortDeposit.selector);
        book.buy(address(this), BUY, address(this));
        assertEq(book.pintoInCurve(), 0);
        assertEq(chirp.balanceOf(address(book)), chirp.SUPPLY());
    }

    function test_plant_must_match_the_stem() public {
        silo.setShortPlant(true);
        silo.setPlant(1e6, 4);
        vm.expectRevert(ChirpBook.ShortPlant.selector);
        book.claim();
        assertEq(book.pintoInCurve(), 0);
        assertEq(book.siloPinto(), 0);
        assertEq(chirp.balanceOf(address(book)), chirp.SUPPLY());
    }

    function test_short_withdraw_reverts() public {
        uint256 out = book.buy(address(this), BUY, address(this));
        silo.setShortWithdraw(1);
        vm.expectRevert(ChirpBook.ShortWithdraw.selector);
        book.sell(address(this), out / 2, address(this));
        _books();
    }

    function test_stranger_cannot_trade() public {
        vm.prank(stranger);
        vm.expectRevert(ChirpBook.OnlyTrader.selector);
        book.buy(stranger, BUY, stranger);
    }

    function test_fee_is_fixed_and_there_is_no_pause() public {
        assertEq(book.FEE_BPS(), 100);
        assertEq(book.buyFeeBps(), 100);
        (bool paused,) = address(book).call(abi.encodeWithSignature("pause(string)", "hail"));
        (bool proposed,) = address(book).call(abi.encodeWithSignature("proposeFee(uint16)", uint16(50)));
        (bool setFee,) = address(book).call(abi.encodeWithSignature("setBuyFee(uint256)", uint256(1)));
        assertFalse(paused);
        assertFalse(proposed);
        assertFalse(setFee);
        book.buy(address(this), BUY, address(this));
        _books();
    }

    function test_toll_starts_at_90_and_the_extra_stays_in_the_price() public {
        book.startClock();
        assertEq(book.buyFeeBps(), 9000);
        uint256 out = book.buy(address(this), BUY, address(this));
        uint256 traded = 10e6;
        uint256 expected = chirp.SUPPLY() * traded / (VIRTUAL + traded);
        assertEq(out, expected);
        assertEq(out, 9_999_900_000_999_990_000_099);
        assertEq(book.pintoInCurve(), BUY);
        _books();
    }

    function test_toll_falls_in_a_straight_line_to_one_percent() public {
        book.startClock();
        vm.warp(block.timestamp + 300);
        assertEq(book.buyFeeBps(), 4550);
        vm.warp(block.timestamp + 299);
        assertEq(book.buyFeeBps(), 115);
        vm.warp(block.timestamp + 1);
        assertEq(book.buyFeeBps(), 100);
        uint256 out = book.buy(address(this), BUY, address(this));
        assertEq(out, 98_990_199_970_202_949_907_959);
        assertEq(book.pintoInCurve(), BUY);
        _books();
    }

    function test_sell_stays_at_one_percent_during_the_toll() public {
        book.startClock();
        uint256 out = book.buy(address(this), BUY, address(this));
        uint256 c = book.chirpReserve();
        uint256 p = book.pintoInCurve();
        uint256 gross = (VIRTUAL + p) * out / (c + out);
        uint256 paid = book.sell(address(this), out, address(this));
        assertEq(paid, gross * 9900 / 10_000);
        assertGt(paid, gross / 10);
        _books();
    }

    function test_clock_starts_once_and_only_from_the_factory() public {
        vm.prank(stranger);
        vm.expectRevert(ChirpBook.OnlyFactory.selector);
        book.startClock();

        ChirpBook fresh = new ChirpBook(chirp, address(pinto), address(silo), address(field), address(peg));
        fresh.setTrader(address(this));
        vm.expectRevert(ChirpBook.NotOpen.selector);
        fresh.startClock();

        book.startClock();
        vm.expectRevert(ChirpBook.ClockStarted.selector);
        book.startClock();
    }

    function test_plant_buyback_burns_without_the_trade_fee() public {
        uint256 supplyBefore = chirp.totalSupply();
        silo.setPlant(1e6, 4);
        book.claim();
        uint256 expected = chirp.SUPPLY() * 1e6 / (VIRTUAL + 1e6);
        assertEq(chirp.totalSupply(), supplyBefore - expected);
        assertEq(book.pintoInCurve(), 1e6);
        assertEq(book.unswept(), 0);
        assertEq(chirp.balanceOf(address(book)), book.chirpReserve());
        assertEq(silo.deposits(address(book), 4), 1e6);
        _books();
    }

    function test_buy_claims_before_it_prices() public {
        silo.setPlant(1e6, 4);
        uint256 out = book.buy(address(this), BUY, address(this));
        uint256 afterYield = chirp.SUPPLY() - chirp.SUPPLY() * 1e6 / (VIRTUAL + 1e6);
        uint256 curveAfterYield = 1e6;
        uint256 traded = 99e6;
        uint256 expected = afterYield * traded / (VIRTUAL + curveAfterYield + traded);
        assertEq(out, expected);
        assertEq(book.pintoInCurve(), 1e6 + BUY);
        assertLt(chirp.totalSupply(), chirp.SUPPLY());
        _books();
    }

    function test_sow_only_below_peg_and_passes_min_temperature() public {
        book.buy(address(this), BUY, address(this));
        uint256 out = chirp.balanceOf(address(this));
        book.sell(address(this), out / 2, address(this));
        assertGt(book.sowPile(), 0);

        uint256 blocked = book.sowPile();
        peg.set(false);
        field.setSoil(1_000_000e6);
        vm.expectRevert(ChirpBook.AbovePeg.selector);
        book.sow(blocked, 0);

        peg.set(true);
        uint256 amount = book.sowPile();
        uint256 cap = 3_488_500_000;
        field.setMaxTemp(cap);
        field.setTemp(cap - 1);
        vm.expectRevert(ChirpBook.BelowMaxTemperature.selector);
        book.sow(amount, cap);
        assertEq(book.sowPile(), amount);
        assertEq(field.lastMinTemp(), 0);

        field.setTemp(cap);
        vm.expectRevert(ChirpBook.BelowMaxTemperature.selector);
        book.sow(amount, cap - 1);
        assertEq(book.sowPile(), amount);
        assertEq(field.lastMinTemp(), 0);

        vm.prank(stranger);
        book.sow(amount, cap);
        uint256 minTemp = cap;
        assertEq(field.lastMinTemp(), minTemp);
        assertEq(book.sowPile(), 0);
        assertEq(book.plotCount(), 1);
        assertEq(field.lastReferrer(), book.REFERRER());
        (uint256 fieldId, uint256 index, uint256 pods) = book.plotAt(0);
        assertEq(fieldId, 0);
        assertEq(index, 46_422_690_411_282);
        assertEq(pods, field.lastPods());
        assertEq(pods, amount + amount * field.temp() / 1e8);
        _books();
    }

    function test_harvest_skips_a_partial_plot_and_burns_a_mature_one() public {
        book.buy(address(this), BUY, address(this));
        uint256 sold = chirp.balanceOf(address(this)) / 2;
        book.sell(address(this), sold, address(this));
        uint256 amount = book.sowPile();
        peg.set(true);
        field.setMaxTemp(3_488_500_000);
        field.setTemp(3_488_500_000);
        book.sow(amount, 3_488_500_000);
        (,, uint256 pods) = book.plotAt(0);
        uint256 index = 46_422_690_411_282;

        field.setMatureAt(0, index + pods - 1);
        book.harvest(0);
        assertEq(field.harvests(), 0);
        assertEq(book.plotCount(), 1);

        field.setMatureAt(0, index + pods);
        uint256 supplyBefore = chirp.totalSupply();
        book.harvest(0);
        assertEq(field.harvests(), 1);
        assertEq(book.plotCount(), 0);
        assertLt(chirp.totalSupply(), supplyBefore);
        assertGt(book.pintoInCurve(), 0);
        _books();
    }

    function test_short_harvest_leaves_the_plot() public {
        book.buy(address(this), BUY, address(this));
        book.sell(address(this), chirp.balanceOf(address(this)) / 2, address(this));
        uint256 amount = book.sowPile();
        field.setMaxTemp(3_488_500_000);
        field.setTemp(3_488_500_000);
        book.sow(amount, 3_488_500_000);
        (,, uint256 pods) = book.plotAt(0);
        field.setMatureAt(0, 46_422_690_411_282 + pods);
        field.setShortHarvest(true);

        uint256 curve = book.pintoInCurve();
        uint256 supply = chirp.totalSupply();
        vm.expectRevert(ChirpBook.ShortHarvest.selector);
        book.harvest(0);
        assertEq(book.plotCount(), 1);
        assertEq(book.pintoInCurve(), curve);
        assertEq(chirp.totalSupply(), supply);
        _books();
    }

    function test_a_valid_friend_adds_a_bonus_plot_and_spends_no_extra_pinto() public {
        book.buy(address(this), BUY, address(this));
        book.sell(address(this), chirp.balanceOf(address(this)) / 2, address(this));
        uint256 amount = book.sowPile();
        uint256 cap = 3_488_500_000;
        field.setMaxTemp(cap);
        field.setTemp(cap);
        field.setEligible(book.REFERRER(), true);

        uint256 soilBefore = field.soil();
        uint256 fieldPinto = pinto.balanceOf(address(field));
        book.sow(amount, cap);
        assertEq(field.lastReferrer(), book.REFERRER());

        uint256 bonusBeans = amount * 50_000 / 1_000_000;
        uint256 mainPods = amount + amount * cap / 1e8;
        uint256 bonusPods = bonusBeans + bonusBeans * cap / 1e8;
        uint256 index = 46_422_690_411_282;
        assertGt(bonusPods, 0);
        assertEq(book.plotCount(), 2);
        assertEq(book.sowPile(), 0);
        assertEq(field.soil(), soilBefore - amount);
        assertEq(pinto.balanceOf(address(field)), fieldPinto + amount);

        (uint256 fieldId, uint256 mainIndex, uint256 pods) = book.plotAt(0);
        assertEq(fieldId, 0);
        assertEq(mainIndex, index);
        assertEq(pods, mainPods);
        (uint256 bonusField, uint256 bonusIndex, uint256 bonus) = book.plotAt(1);
        assertEq(bonusField, 0);
        assertEq(bonusIndex, index + mainPods);
        assertEq(bonus, bonusPods);

        field.setMatureAt(0, index + mainPods);
        book.harvest(0);
        assertEq(book.plotCount(), 1);
        (,, uint256 waiting) = book.plotAt(0);
        assertEq(waiting, bonusPods);

        field.setMatureAt(0, index + mainPods + bonusPods);
        book.harvest(0);
        assertEq(book.plotCount(), 0);
        _books();
    }

    function test_an_ineligible_friend_sows_one_plot() public {
        book.buy(address(this), BUY, address(this));
        book.sell(address(this), chirp.balanceOf(address(this)) / 2, address(this));
        uint256 amount = book.sowPile();
        uint256 cap = 3_488_500_000;
        field.setMaxTemp(cap);
        field.setTemp(cap);

        book.sow(amount, cap);
        assertEq(book.plotCount(), 1);
        assertEq(field.lastReferrer(), book.REFERRER());
        _books();
    }

    function test_a_reverting_referral_still_sows() public {
        book.buy(address(this), BUY, address(this));
        book.sell(address(this), chirp.balanceOf(address(this)) / 2, address(this));
        uint256 amount = book.sowPile();
        uint256 cap = 3_488_500_000;
        field.setMaxTemp(cap);
        field.setTemp(cap);
        field.setEligible(book.REFERRER(), true);
        field.setReferralReverts(true);

        uint256 soilBefore = field.soil();
        book.sow(amount, cap);
        assertEq(book.plotCount(), 1);
        assertEq(book.sowPile(), 0);
        assertEq(field.soil(), soilBefore - amount);
        (,, uint256 pods) = book.plotAt(0);
        assertEq(pods, amount + amount * cap / 1e8);
        _books();
    }

    function test_a_bonus_the_field_does_not_hold_is_not_recorded() public {
        book.buy(address(this), BUY, address(this));
        book.sell(address(this), chirp.balanceOf(address(this)) / 2, address(this));
        uint256 amount = book.sowPile();
        uint256 cap = 3_488_500_000;
        field.setMaxTemp(cap);
        field.setTemp(cap);
        field.setEligible(book.REFERRER(), true);
        field.setBonusMismatch(true);

        book.sow(amount, cap);
        assertEq(book.plotCount(), 1);
        (,, uint256 pods) = book.plotAt(0);
        assertEq(pods, amount + amount * cap / 1e8);
        assertEq(book.sowPile(), 0);
        _books();
    }

    function test_reenter_on_plant_reverts() public {
        silo.setReenter(true);
        silo.setPlant(1e6, 4);
        vm.expectRevert(ChirpBook.Locked.selector);
        book.claim();
    }

    function test_donated_pinto_joins_the_sow_pile_not_the_price() public {
        pinto.mint(address(book), 5e6);
        book.claim();
        assertEq(book.sowPile(), 5e6);
        assertEq(book.pintoInCurve(), 0);
        _books();
    }

    /// @dev Audit 2026-11-17: 200 one-raw sows put unripe plots ahead of ripe ones. From 0 the
    ///      32-plot scan stalls; a later `start` reaches the rest.
    function test_dust_sows_cannot_stall_harvest() public {
        book.buy(address(this), BUY, address(this));
        book.sell(address(this), chirp.balanceOf(address(this)) / 2, address(this));
        uint256 cap = 3_488_500_000;
        field.setSoil(1_000_000e6);
        field.setMaxTemp(cap);
        field.setTemp(cap);
        book.sow(1000, cap);
        vm.startPrank(stranger);
        for (uint256 i; i < 200; i++) book.sow(1, cap);
        vm.stopPrank();
        (, uint256 idxR, uint256 podsR) = book.plotAt(40);
        uint256 ripeEnd = idxR + podsR;
        field.setMatureAt(0, ripeEnd);

        for (uint256 k; k < 50; k++) book.harvest(0);
        assertGt(_ripeLeft(ripeEnd), 0, "scan from 0 stalls");

        for (uint256 start = 32; _ripeLeft(ripeEnd) != 0; start += 32) {
            book.harvest(start);
        }
        assertEq(field.harvests(), 41);
        _books();
    }

    function _ripeLeft(uint256 ripeEnd) internal view returns (uint256 n) {
        for (uint256 i; i < book.plotCount(); i++) {
            (, uint256 idx, uint256 pods) = book.plotAt(i);
            if (idx + pods <= ripeEnd) n++;
        }
    }

    /// @dev Audit 2026-11-17: anyone can transferDeposit a dust deposit to the book. It must not freeze trading.
    function _gift(int96 stem, uint256 amount) internal {
        uint256 had = silo.deposits(address(book), stem);
        stdstore.target(address(silo)).sig("deposits(address,int96)").with_key(address(book)).with_key(
            uint256(int256(stem))
        ).checked_write(had + amount);
    }

    function test_gifted_deposit_cannot_freeze_trading() public {
        uint256 out = book.buy(address(this), BUY, address(this));
        _gift(1, 1); // today's deposit stem
        book.buy(address(this), BUY, address(this));
        pinto.mint(address(silo), 5);
        silo.setPlant(5, 9);
        _gift(9, 1); // today's plant stem
        book.sell(address(this), out, address(this));
        _books();
    }
}
