// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Chirp} from "../src/Chirp.sol";
import {ChirpBook} from "../src/ChirpBook.sol";
import {MockPinto, MockSilo, MockField, MockPeg} from "./mocks/Mocks.sol";

/// @dev Random buys, sells, gifts, plants, sows, harvests and clock moves against the mocks.
contract BookHandler is Test {
    Chirp public chirp;
    ChirpBook public book;
    MockPinto public pinto;
    MockSilo public silo;
    MockField public field;
    int96 public stem = 1;

    constructor(Chirp c, ChirpBook b, MockPinto p, MockSilo s, MockField f) {
        chirp = c;
        book = b;
        pinto = p;
        silo = s;
        field = f;
        pinto.approve(address(book), type(uint256).max);
        chirp.approve(address(book), type(uint256).max);
    }

    function buy(uint256 amount) external {
        amount = bound(amount, 1, 5_000_000e6);
        pinto.mint(address(this), amount);
        try book.buy(address(this), amount, address(this)) {} catch (bytes memory e) {
            require(bytes4(e) == ChirpBook.ZeroOut.selector, "buy reverted");
        }
    }

    function sell(uint256 amount) external {
        uint256 bal = chirp.balanceOf(address(this));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try book.sell(address(this), amount, address(this)) {} catch (bytes memory e) {
            // Dust can round to zero Pinto. Anything else, SellTooBig included, is a bug.
            require(bytes4(e) == ChirpBook.ZeroOut.selector, "sell reverted");
        }
    }

    function giftPinto(uint256 amount) external {
        pinto.mint(address(book), bound(amount, 0, 100_000e6));
        book.claim(); // a gift is counted at the next sync
    }

    function giftChirp(uint256 amount) external {
        uint256 bal = chirp.balanceOf(address(this));
        if (bal == 0) return;
        chirp.transfer(address(book), bound(amount, 0, bal));
        book.claim();
    }

    function plant(uint256 beans) external {
        beans = bound(beans, 1, 50_000e6);
        pinto.mint(address(silo), beans); // Pinto mints earned beans into the silo.
        silo.setPlant(beans, stem);
        book.claim();
    }

    function newSeason() external {
        stem++;
        silo.setNextStem(stem);
        vm.warp(block.timestamp + 1 hours);
    }

    function sow(uint256 amount) external {
        uint256 pile = book.sowPile();
        if (pile == 0) return;
        book.sow(bound(amount, 1, pile), field.temp());
    }

    function harvest(uint256 start) external {
        field.setMatureAt(0, type(uint128).max);
        uint256 n = book.plotCount();
        book.harvest(n == 0 ? 0 : bound(start, 0, n - 1));
    }
}

contract ChirpInvariantTest is Test {
    uint256 internal constant VIRTUAL = 1_000_000e6;

    Chirp internal chirp;
    ChirpBook internal book;
    MockPinto internal pinto;
    MockSilo internal silo;
    MockField internal field;
    BookHandler internal handler;

    function setUp() public {
        pinto = new MockPinto();
        silo = new MockSilo(pinto);
        field = new MockField(pinto);
        MockPeg peg = new MockPeg();
        field.setMaxTemp(field.temp());
        chirp = new Chirp();
        book = new ChirpBook(chirp, address(pinto), address(silo), address(field), address(peg));
        silo.setBook(address(book));
        chirp.setBook(address(book));
        chirp.transfer(address(book), chirp.SUPPLY());
        handler = new BookHandler(chirp, book, pinto, silo, field);
        book.setTrader(address(handler));
        book.open(VIRTUAL);
        targetContract(address(handler));
    }

    function invariant_books_balance() public view {
        assertEq(chirp.balanceOf(address(book)), book.chirpReserve(), "chirp");
        assertEq(book.siloPinto(), book.pintoInCurve() + book.unswept(), "silo");
        assertEq(pinto.balanceOf(address(book)), book.sowPile(), "pile");
        assertEq(book.siloAccounted(), book.siloPinto(), "stems");
        assertLe(book.siloPinto(), pinto.balanceOf(address(silo)), "silo holds it");
        assertGe(book.pricePintoPerChirp(), book.openingPrice(), "price floor");
    }

    /// @dev Every outstanding Chirp sold in one go never asks for virtual Pinto.
    function invariant_everyone_can_exit() public {
        uint256 out = chirp.balanceOf(address(handler));
        if (out == 0) return;
        uint256 p = book.pintoInCurve();
        uint256 gross = (VIRTUAL + p) * out / (book.chirpReserve() + out);
        assertLe(gross, p, "exit needs virtual pinto");
        uint256 snap = vm.snapshotState();
        vm.prank(address(handler));
        try book.sell(address(handler), out, address(handler)) {} catch (bytes memory e) {
            assertEq(bytes4(e), ChirpBook.ZeroOut.selector, "full exit reverted");
        }
        vm.revertToState(snap);
    }
}

contract ChirpRoundTripFuzz is Test {
    function test_fuzz_buy_then_sell_never_profits(uint256 seed, uint256 amount) public {
        MockPinto pinto = new MockPinto();
        MockSilo silo = new MockSilo(pinto);
        MockField field = new MockField(pinto);
        Chirp chirp = new Chirp();
        ChirpBook book = new ChirpBook(chirp, address(pinto), address(silo), address(field), address(new MockPeg()));
        silo.setBook(address(book));
        chirp.setBook(address(book));
        chirp.transfer(address(book), chirp.SUPPLY());
        book.setTrader(address(this));
        book.open(bound(seed, 1e6, 100_000_000e6));
        pinto.approve(address(book), type(uint256).max);
        chirp.approve(address(book), type(uint256).max);

        amount = bound(amount, 1, 50_000_000e6);
        pinto.mint(address(this), amount);
        uint256 got;
        try book.buy(address(this), amount, address(this)) returns (uint256 o) {
            got = o;
        } catch {
            return; // ZeroOut on dust
        }
        try book.sell(address(this), got, address(this)) returns (uint256 paid) {
            assertLt(paid, amount);
        } catch (bytes memory e) {
            assertEq(bytes4(e), ChirpBook.ZeroOut.selector);
        }
    }
}
