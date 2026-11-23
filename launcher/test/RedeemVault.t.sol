// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    MockWETH,
    MockCbEth,
    MockPinto,
    MockPump,
    MockWell,
    MockV3Pool,
    MockSwapRouter,
    MockSiloWithConvert
} from "./mocks/LauncherMocks.sol";
import {RouteHarness} from "./fork/PintoRoute.t.sol";
import {VaultBase} from "../src/VaultBase.sol";
import {RedeemVault} from "../src/RedeemVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {
    WETH,
    CBETH,
    PINTO,
    PINTO_DIAMOND,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    V3_WETH_CBETH_POOL,
    SWAP_ROUTER02,
    SUPPLY,
    MERGE_GAS
} from "../src/Constants.sol";

/// RedeemVault with a handle on _deposit, so tests can set the Silo Pinto directly.
contract RedeemHarness is RedeemVault {
    constructor(LaunchToken coin, address safe, address creatorPayout, uint16 creatorBps)
        RedeemVault(coin, safe, creatorPayout, creatorBps)
    {}

    /// Deposits `amount` Pinto the vault already holds.
    function deposit(uint256 amount) external {
        _deposit(amount);
    }
}

contract RedeemVaultTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant CREATOR = address(0xC0FFEE);
    address constant ALICE = address(0xA11CE);
    address constant POOL = address(0x9001);

    MockSiloWithConvert silo = MockSiloWithConvert(PINTO_DIAMOND);
    MockPinto pinto = MockPinto(PINTO);
    LaunchToken coin;
    RedeemHarness vault;

    function setUp() public {
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);
        vm.etch(PINTO_DIAMOND, address(new MockSiloWithConvert()).code);

        // VaultBaseTest's market: 690k Pinto / 6.5 cbETH, spot = EMA, router spot = TWAP.
        MockWell(CBETH_WELL).setReserves(690_000e6, 6.5 ether);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 690_000e6, 6.5 ether);
        pinto.mint(CBETH_WELL, 690_000e6);
        MockCbEth(CBETH).mint(CBETH_WELL, 6.5 ether);
        MockV3Pool(V3_WETH_CBETH_POOL).setTick(1345);
        RouteHarness h = new RouteHarness();
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, h.cbEthForWeth(1 ether));
        MockCbEth(CBETH).mint(SWAP_ROUTER02, 100 ether);

        coin = new LaunchToken("Coin", "COIN", "", "", address(this));
        vault = new RedeemHarness(coin, SAFE, CREATOR, 0);
        coin.approve(address(vault), type(uint256).max);
    }

    function _depositAt(int96 stem, uint256 amount) internal {
        silo.setNextStem(stem);
        pinto.mint(address(vault), amount);
        vault.deposit(amount);
    }

    /// The tally equals what the Silo holds for the vault, stem by stem (ruling R6's first half).
    function _assertTally() internal view {
        int96[] memory s = vault.stems();
        uint256 sum;
        for (uint256 i; i < s.length; i++) {
            assertEq(silo.deposits(address(vault), s[i]), vault.stemAmount(s[i]), "stem tally");
            sum += vault.stemAmount(s[i]);
        }
        assertEq(sum, vault.siloPinto(), "sum of stems");
        assertEq(silo.held(address(vault)), vault.siloPinto(), "silo holds the tally");
    }

    // ---- redeem ----

    function test_redeem_pays_share() public {
        _depositAt(1, 1_000e6);
        assertEq(coin.totalSupply(), 1e27);

        uint256 out = vault.redeem(1e24, 0.99e6, ALICE);

        assertEq(out, 0.99e6);
        assertEq(pinto.balanceOf(ALICE), 0.99e6);
        assertEq(vault.siloPinto(), 1_000e6 - 0.99e6);
        assertEq(coin.totalSupply(), 1e27 - 1e24);
        assertEq(coin.balanceOf(address(vault)), 0);
        assertEq(pinto.balanceOf(address(vault)), 0);
        _assertTally();
    }

    /// Coins still in the pool count: a holder of all circulating coins gets 0.1% of the vault for 0.1% of supply.
    function test_redeem_counts_pool_coins() public {
        _depositAt(1, 1_000e6);
        coin.transfer(POOL, SUPPLY - 1e24);

        uint256 out = vault.redeem(1e24, 0, ALICE);

        assertEq(out, 0.99e6);
        assertEq(vault.siloPinto(), 1_000e6 - 0.99e6);
    }

    function test_redeem_zero_out_reverts() public {
        // Nothing in the Silo.
        vm.expectRevert(VaultBase.ZeroOut.selector);
        vault.redeem(1e24, 0, ALICE);

        // A share that rounds to 0: 0.5 coin of 1e9 against 1,000 Pinto.
        _depositAt(1, 1_000e6);
        vm.expectRevert(VaultBase.ZeroOut.selector);
        vault.redeem(0.5e18, 0, ALICE);

        vm.expectRevert(VaultBase.ZeroOut.selector);
        vault.redeem(0, 0, ALICE);

        assertEq(coin.balanceOf(address(this)), SUPPLY, "no coins burned");
        assertEq(coin.totalSupply(), SUPPLY);
        assertEq(vault.siloPinto(), 1_000e6);
    }

    /// Backing per coin after a redemption is never below what it was.
    function test_redeem_raises_backing_for_rest(uint256 siloAmount, uint256 amount) public {
        siloAmount = bound(siloAmount, 1, 1e15);
        amount = bound(amount, 1, SUPPLY);
        _depositAt(1, siloAmount);
        uint256 gross = amount * siloAmount / SUPPLY;
        vm.assume(gross - (gross + 99) / 100 != 0); // the fee rounds up (R20)

        uint256 out = vault.redeem(amount, 0, ALICE);

        uint256 siloAfter = vault.siloPinto();
        uint256 supplyAfter = coin.totalSupply();
        assertEq(siloAfter, siloAmount - out);
        assertEq(supplyAfter, SUPPLY - amount);
        // siloAfter / supplyAfter >= siloAmount / SUPPLY, cross-multiplied.
        assertGe(siloAfter * SUPPLY, siloAmount * supplyAfter);
        _assertTally();
    }

    function test_redeem_slippage() public {
        _depositAt(1, 1_000e6);
        vm.expectRevert(RedeemVault.Slippage.selector);
        vault.redeem(1e24, 0.99e6 + 1, ALICE);
    }

    function test_redeem_zero_recipient_reverts() public {
        _depositAt(1, 1_000e6);
        vm.expectRevert(VaultBase.ZeroAddress.selector);
        vault.redeem(1e24, 0, address(0));
    }

    /// Newest stems first, across stems, and the books still match the Silo.
    function test_redeem_walks_stems() public {
        _depositAt(1, 500e6);
        _depositAt(2, 500e6);

        vault.redeem(SUPPLY / 2, 0, ALICE); // gross 500e6, out 495e6

        assertEq(pinto.balanceOf(ALICE), 495e6);
        assertEq(silo.deposits(address(vault), 2), 5e6);
        assertEq(silo.deposits(address(vault), 1), 500e6);
        _assertTally();
    }

    // ---- claim ----

    function test_claim_compounds_at_peg() public {
        _depositAt(1, 1_000e6);
        silo.setPlant(50e6, 3);

        vault.claim();

        assertEq(vault.siloPinto(), 1_050e6);
        assertEq(vault.stemAmount(3), 50e6);
        _assertTally();
        // A redemption now shares the planted yield.
        assertEq(vault.redeem(1e24, 0, ALICE), 1.0395e6);
    }

    function test_claim_noop_below_peg() public {
        _depositAt(1, 1_000e6);
        silo.setBelow(true);
        silo.setPlant(50e6, 3);

        vault.claim();

        assertEq(vault.siloPinto(), 1_000e6);
        assertEq(silo.plantBeans(), 50e6, "plant() not called");
        assertEq(vault.stems().length, 1);
    }

    // ---- merge ----

    /// Three finished stems plus the convert's new one: four > 3, so convert() merges the finished three.
    function test_merge_called_after_convert() public {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(2, 200e6);
        _depositAt(3, 300e6);
        silo.setNextStem(5); // the tip; stem 5 is germinating
        MockWETH(WETH).mint(address(vault), 0.05 ether);

        vault.convert();

        uint256 fresh = vault.siloPinto() - 600e6;
        assertGt(fresh, 0);
        // toStem = 5 - (4*100 + 3*200 + 2*300) / 600 = 5 - 2 = 3 (the measured stem rule).
        int96[] memory s = vault.stems();
        assertEq(s.length, 2);
        assertEq(s[0], 3, "merged stem first (oldest)");
        assertEq(s[1], 5);
        assertEq(vault.stemAmount(3), 600e6);
        assertEq(vault.stemAmount(5), fresh);
        assertEq(silo.deposits(address(vault), 1), 0);
        assertEq(silo.deposits(address(vault), 2), 0);
        _assertTally();
    }

    /// R29: with a merge due, convert() refuses a gas budget that cannot leave MERGE_GAS for it, so an
    /// estimate-sized caller pays for the merge instead of having its out-of-gas swallowed by the catch.
    function test_convert_reverts_without_merge_gas() public {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(2, 200e6);
        _depositAt(3, 300e6);
        silo.setNextStem(5);
        MockWETH(WETH).mint(address(vault), 0.05 ether);

        vm.expectRevert(RedeemVault.MergeGas.selector);
        vault.convert{gas: MERGE_GAS}();

        vault.convert{gas: MERGE_GAS + 1_000_000}();
        assertEq(vault.stems().length, 2, "merged");
    }

    /// No merge due (three stems after the convert): the guard does not apply.
    function test_convert_no_merge_needs_no_merge_gas() public {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(2, 200e6);
        silo.setNextStem(5);
        MockWETH(WETH).mint(address(vault), 0.05 ether);

        vault.convert{gas: MERGE_GAS}();
        assertEq(vault.stems().length, 3);
    }

    /// Three stems is not "more than 3": convert() leaves them.
    function test_convert_no_merge_at_three() public {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(2, 200e6);
        silo.setNextStem(5);
        MockWETH(WETH).mint(address(vault), 0.05 ether);

        vault.convert();

        assertEq(vault.stems().length, 3);
    }

    function test_merge_skips_germinating() public {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(5, 400e6);
        _depositAt(6, 50e6);

        // One finished stem: nothing to merge.
        vault.merge();
        assertEq(vault.stems().length, 3);

        _depositAt(2, 200e6);
        vault.merge();

        int96[] memory s = vault.stems();
        assertEq(s.length, 3);
        assertEq(s[0], 2);
        assertEq(s[1], 5);
        assertEq(s[2], 6);
        assertEq(vault.stemAmount(5), 400e6);
        assertEq(vault.stemAmount(6), 50e6);
        // toStem = 6 - (5*100 + 4*200) / 300 = 6 - 4 = 2.
        assertEq(vault.stemAmount(2), 300e6);
        assertEq(vault.stemAmount(1), 0);
        assertEq(vault.siloPinto(), 750e6);
        _assertTally();
    }

    /// Stems 1-3 finished, then convert() adds germinating stem 5 with the mock Silo set to fail as `fault`.
    function _convertWithFault(uint8 fault) internal {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(2, 200e6);
        _depositAt(3, 300e6);
        silo.setNextStem(5);
        silo.setFault(fault);
        MockWETH(WETH).mint(address(vault), 0.05 ether);

        vault.convert();

        // The merge was rolled back whole, Pinto's side included: four stems, books = Silo.
        int96[] memory s = vault.stems();
        assertEq(s.length, 4);
        assertEq(s[0], 1);
        assertEq(s[3], 5);
        assertEq(vault.stemAmount(1), 100e6);
        assertEq(silo.deposits(address(vault), 1), 100e6);
        assertEq(silo.deposits(address(vault), 3), 300e6);
        assertGt(vault.siloPinto(), 600e6);
        _assertTally();
    }

    /// Pinto refuses the merge: convert() goes on, merge() reverts with Pinto's reason.
    function test_convert_survives_refused_merge() public {
        _convertWithFault(1);
        vm.expectRevert(bytes("convert refused"));
        vault.merge();
    }

    /// Pinto returns less than the total: caught in convert(), ShortMerge from merge().
    function test_convert_survives_short_merge() public {
        _convertWithFault(2);
        vm.expectRevert(RedeemVault.ShortMerge.selector);
        vault.merge();
    }

    /// The germinating-stem view reverts (e.g. a Diamond upgrade drops it): convert() still goes on.
    function test_convert_survives_missing_view() public {
        _convertWithFault(3);
        vm.expectRevert(bytes("view gone"));
        vault.merge();
    }

    function test_merge_self_only_self() public {
        vm.expectRevert(RedeemVault.OnlySelf.selector);
        vault.mergeSelf();
    }

    /// After a merge the merged (oldest) deposit is withdrawn last: a redeem takes the germinating stems first.
    function test_redeem_after_merge_takes_newest_first() public {
        silo.setGerminatingStem(5);
        _depositAt(1, 100e6);
        _depositAt(2, 200e6);
        _depositAt(5, 400e6);
        _depositAt(6, 50e6);
        vault.merge(); // stems [2 (300), 5 (400), 6 (50)]

        uint256 out = vault.redeem(SUPPLY / 10, 0, ALICE); // gross 75e6, fee 0.75e6

        assertEq(out, 74.25e6);
        assertEq(silo.deposits(address(vault), 6), 0);
        assertEq(silo.deposits(address(vault), 5), 400e6 - 24.25e6);
        assertEq(silo.deposits(address(vault), 2), 300e6, "merged deposit untouched");
        _assertTally();
    }

    // ---- R20: fee rounding, empty supply, sequential redeems ----

    function test_redeem_fee_rounds_up() public {
        _depositAt(1, 1_000e6);
        // gross 150 -> fee ceil(1.5) = 2.
        assertEq(vault.redeem(1.5e20, 0, ALICE), 148);
        // gross 1 -> fee 1 -> nothing out.
        vm.expectRevert(VaultBase.ZeroOut.selector);
        vault.redeem(1e18, 0, ALICE);
    }

    function test_redeem_zero_supply_reverts() public {
        _depositAt(1, 1_000e6);
        vault.redeem(SUPPLY, 0, ALICE);
        assertEq(coin.totalSupply(), 0);
        assertEq(vault.siloPinto(), 10e6, "the fee stays");
        vm.expectRevert(VaultBase.ZeroOut.selector);
        vault.redeem(0, 0, ALICE);
    }

    /// Two redemptions, then the last holder redeems everything left: books always match the Silo and backing
    /// per coin never falls.
    function testFuzz_sequential_redeems(uint256 siloAmount, uint256 a1, uint256 a2) public {
        _sequentialRedeems(siloAmount, a1, a2);
    }

    /// Counterexample: both fuzzed redeems take SUPPLY/2, so the third step meets supply == 0.
    function test_sequential_redeems_full_supply_regression() public {
        _sequentialRedeems(
            166280377232851291607224495994490289856734991747707723310528, type(uint256).max, type(uint256).max
        );
    }

    function _sequentialRedeems(uint256 siloAmount, uint256 a1, uint256 a2) internal {
        siloAmount = bound(siloAmount, 1, 1e15);
        _depositAt(1, siloAmount / 2 + 1);
        _depositAt(2, siloAmount / 2);
        uint256[3] memory amounts = [bound(a1, 0, SUPPLY / 2), bound(a2, 0, SUPPLY / 2), 0];
        for (uint256 i; i < 3; i++) {
            uint256 amount = i == 2 ? coin.balanceOf(address(this)) : amounts[i];
            uint256 s0 = vault.siloPinto();
            uint256 t0 = coin.totalSupply();
            if (t0 == 0) {
                // everything already redeemed: nothing left to claim, and the fee residue stays in the Silo
                assertEq(coin.balanceOf(address(this)), 0);
                assertEq(vault.siloPinto(), s0, "residue moved");
                vm.expectRevert(VaultBase.ZeroOut.selector);
                vault.redeem(amount, 0, ALICE);
                continue;
            }
            uint256 gross = amount * s0 / t0;
            uint256 expected = gross - (gross + 99) / 100;
            if (expected == 0) {
                vm.expectRevert(VaultBase.ZeroOut.selector);
                vault.redeem(amount, 0, ALICE);
                continue;
            }
            assertEq(vault.redeem(amount, 0, ALICE), expected);
            _assertTally();
            if (coin.totalSupply() > 0) assertGe(vault.siloPinto() * t0, s0 * coin.totalSupply(), "backing per coin fell");
        }
    }

    // ---- seed ----

    function test_seed_books_plain_transfer() public {
        silo.setNextStem(7);
        pinto.mint(address(vault), 500e6); // a plain transfer in
        vm.expectEmit(true, false, false, true, address(vault));
        emit VaultBase.Seeded(ALICE, 500e6);
        vm.prank(ALICE);
        vault.seed();
        assertEq(vault.siloPinto(), 500e6);
        assertEq(vault.stemAmount(7), 500e6);
        assertEq(pinto.balanceOf(address(vault)), 0, "nothing left loose");
        _assertTally();
    }

    function test_seed_nothing_reverts() public {
        vm.expectRevert(VaultBase.NothingPending.selector);
        vault.seed();
    }

    function test_seed_raises_redeem_value() public {
        _depositAt(1, 1_000e6);
        uint256 coins = coin.totalSupply() / 10;
        uint256 before = coins * vault.siloPinto() / coin.totalSupply();
        pinto.mint(address(vault), 1_000e6);
        vault.seed();
        assertEq(coins * vault.siloPinto() / coin.totalSupply(), before * 2, "seeding the same again doubles the share");
    }

    /// redeem, claim, merge and seed share VaultBase's lock: a Silo calling back mid-convert is refused.
    function test_entry_points_locked() public {
        _depositAt(1, 1_000e6);
        bytes[4] memory calls = [
            abi.encodeCall(RedeemVault.redeem, (1e24, 0, ALICE)),
            abi.encodeCall(RedeemVault.claim, ()),
            abi.encodeCall(RedeemVault.merge, ()),
            abi.encodeCall(VaultBase.seed, ())
        ];
        for (uint256 i; i < 4; i++) {
            silo.setReenter(address(vault), calls[i]);
            MockWETH(WETH).mint(address(vault), 0.05 ether);
            vm.expectRevert(VaultBase.Locked.selector);
            vault.convert();
        }
    }
}
