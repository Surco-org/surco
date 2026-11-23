// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
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
import {LauncherFactory} from "../src/LauncherFactory.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {VeChirp} from "../src/VeChirp.sol";
import {CollectiveSilo} from "../src/CollectiveSilo.sol";
import {
    WETH,
    CBETH,
    PINTO,
    PINTO_DIAMOND,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    V3_WETH_CBETH_POOL,
    SWAP_ROUTER02,
    LAUNCH_FEE,
    TOLL_WINDOW
} from "../src/Constants.sol";

contract CollectiveSiloTest is Test {
    address internal constant HOOK = address(uint160(0x2AEC | (uint256(0xB0B) << 148)));
    address internal constant SAFE = address(0x5AFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B1);
    address internal constant KEEPER = address(0xBEEF);

    MockSiloWithConvert internal silo = MockSiloWithConvert(PINTO_DIAMOND);
    MockPinto internal pinto = MockPinto(PINTO);
    MockWETH internal weth = MockWETH(WETH);
    MockCbEth internal cbeth = MockCbEth(CBETH);

    IPoolManager internal manager;
    LauncherFactory internal factory;
    LauncherHook internal hook;
    LaunchToken internal chirp;
    VeChirp internal ve;
    CollectiveSilo internal collective;
    address internal coinA;
    address internal coinB;

    function setUp() public {
        vm.warp(1_800_000_000);
        // Etch mocks at the Base protocol addresses (exact same setup as BurnVault.t.sol / LauncherInvariant.t.sol).
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(PINTO_DIAMOND, address(new MockSiloWithConvert()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);

        // Configure deterministic 1:1 WETH<->cbETH and 1 cbETH = 2,000 Pinto rates.
        MockV3Pool(V3_WETH_CBETH_POOL).setTick(0);
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, 1e18);
        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, 1e18);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 2_000_000e6, 1_000e18);
        MockWell(CBETH_WELL).setReserves(2_000_000e6, 1_000e18);

        // Fund mocks so swaps can pay out.
        weth.mint(SWAP_ROUTER02, 1_000 ether);
        cbeth.mint(SWAP_ROUTER02, 1_000 ether);
        cbeth.mint(CBETH_WELL, 1_000 ether);
        pinto.mint(CBETH_WELL, 2_000_000e6);

        manager = new PoolManager(address(this));
        // Predict factory address or deploy hook with deployCodeTo.
        chirp = new LaunchToken("Chirp", "CHIRP", "", "", address(this));
        // Deploy hook, VeChirp, CollectiveSilo, Factory cleanly.
        ve = new VeChirp(IERC20(address(chirp)), LauncherHook(HOOK), "https://surcofi.com/api/launcher/ve/");
        collective = new CollectiveSilo(manager, LauncherHook(HOOK), ve);
        factory = new LauncherFactory(manager, LauncherHook(HOOK), SAFE, address(collective));
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(factory), WETH), HOOK);
        hook = LauncherHook(HOOK);
        weth.mint(address(manager), 1_000 ether);

        // Launch two coins with 0.05 ETH first buy (seeds EMA immediately) + 0.0001 ETH launch fee each.
        vm.deal(address(this), 10 ether);
        (coinA,,) = factory.launch{value: 0.05 ether + LAUNCH_FEE}(
            LauncherFactory.Params("CoinA", "A", "", "", LauncherFactory.Mode.Burn, 100, 1000, ALICE)
        );
        (coinB,,) = factory.launch{value: 0.05 ether + LAUNCH_FEE}(
            LauncherFactory.Params("CoinB", "B", "", "", LauncherFactory.Mode.Burn, 100, 1000, BOB)
        );

        chirp.transfer(ALICE, 1_000 ether);
        chirp.transfer(BOB, 1_000 ether);
        vm.prank(ALICE);
        chirp.approve(address(ve), type(uint256).max);
        vm.prank(BOB);
        chirp.approve(address(ve), type(uint256).max);
    }

    function test_launch_fees_convert_and_seed_into_silo() public {
        // Two launches sent 2 * LAUNCH_FEE WETH to CollectiveSilo.
        assertEq(weth.balanceOf(address(collective)), 2 * LAUNCH_FEE);

        vm.prank(KEEPER);
        collective.convert();
        assertGt(collective.siloPinto(), 0, "launch fees converted into Silo Pinto");
        assertEq(weth.balanceOf(address(collective)), 0);
        assertGt(weth.balanceOf(KEEPER), 0, "keeper received WETH tip");

        // Voluntary seed() adds Pinto directly into principal.
        uint256 before = collective.siloPinto();
        pinto.mint(address(collective), 500e6);
        collective.seed();
        assertEq(collective.siloPinto() - before, 500e6);
    }

    function test_full_cycle_plant_distribute_and_claim_split_across_two_stakers_and_two_coins() public {
        // Seed principal so Silo is active.
        pinto.mint(address(collective), 1_000e6);
        collective.seed();
        uint256 principal = collective.siloPinto();

        // Day d0: Alice locks 365 Chirp permanently on coinA (weight = 365).
        // Bob locks 365 Chirp for 365 days on coinA (weight = 365 on d0+1 -> 50/50 split on coinA),
        // AND Bob locks 365 Chirp permanently on coinB (weight = 365 -> total weight = 1095: 2/3 coinA, 1/3 coinB).
        uint32 d0 = ve.currentDay();
        vm.prank(ALICE);
        uint256 idAlice = ve.lock(365 ether, 0, true, coinA);
        vm.startPrank(BOB);
        uint256 idBobA = ve.lock(365 ether, 365, false, coinA);
        uint256 idBobB = ve.lock(365 ether, 0, true, coinB);
        vm.stopPrank();

        // Advance past toll & into day d0 + 1.
        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        uint32 d1 = ve.currentDay();
        assertEq(d1, d0 + 1);

        // Above peg: Silo prints 300 Pinto on d1!
        silo.setBelow(false);
        silo.setPlant(300e6, 10);
        pinto.mint(PINTO_DIAMOND, 300e6);
        uint256 planted = collective.plant();
        assertEq(planted, 300e6);
        assertEq(collective.dayPinto(d1), 300e6);
        assertEq(collective.dayTotalWeight(d1), 1095 ether);

        // Cannot distribute d1 while still on d1.
        uint32[] memory daysArr = new uint32[](1);
        daysArr[0] = d1;
        vm.expectRevert(CollectiveSilo.DayNotFinished.selector);
        collective.distribute(coinA, daysArr, 1_000e6);

        // Advance to d2 so d1 is finalized.
        vm.warp(block.timestamp + 1 days);

        // Distribute coinA (200 Pinto entitled) and coinB (100 Pinto entitled).
        vm.prank(KEEPER);
        uint256 boughtA = collective.distribute(coinA, daysArr, 1_000e6);
        assertGt(boughtA, 0);
        assertEq(collective.coinDayPaidPinto(coinA, d1), 200e6);

        vm.prank(KEEPER);
        uint256 boughtB = collective.distribute(coinB, daysArr, 1_000e6);
        assertGt(boughtB, 0);
        assertEq(collective.coinDayPaidPinto(coinB, d1), 100e6);

        // Principal untouched!
        assertEq(collective.siloPinto(), principal, "principal never touched");
        assertEq(collective.yieldPinto(), 0);

        // Alice and Bob each claim 50% of boughtA; Bob claims 100% of boughtB.
        {
            uint256 aliceBefore = IERC20(coinA).balanceOf(ALICE);
            vm.prank(ALICE);
            (address cA1, uint256 payAlice) = collective.claim(idAlice, 30);
            assertEq(cA1, coinA);
            assertEq(payAlice, boughtA / 2);
            assertEq(IERC20(coinA).balanceOf(ALICE) - aliceBefore, payAlice);
        }
        {
            uint256 bobBeforeA = IERC20(coinA).balanceOf(BOB);
            vm.prank(BOB);
            (address cA2, uint256 payBobA) = collective.claim(idBobA, 30);
            assertEq(cA2, coinA);
            assertEq(payBobA, boughtA / 2);
            assertEq(IERC20(coinA).balanceOf(BOB) - bobBeforeA, payBobA);
        }
        {
            uint256 bobBeforeB = IERC20(coinB).balanceOf(BOB);
            vm.prank(BOB);
            (address cB, uint256 payBobB) = collective.claim(idBobB, 30);
            assertEq(cB, coinB);
            assertEq(payBobB, boughtB);
            assertEq(IERC20(coinB).balanceOf(BOB) - bobBeforeB, payBobB);
        }

        // Second claim is a clean 0 no-op.
        vm.prank(ALICE);
        (, uint256 payAgain) = collective.claim(idAlice, 30);
        assertEq(payAgain, 0);
    }

    function test_zero_staker_day_rolls_yield_into_principal() public {
        pinto.mint(address(collective), 100e6);
        collective.seed();

        silo.setBelow(false);
        silo.setPlant(50e6, 11);
        pinto.mint(PINTO_DIAMOND, 50e6);
        collective.plant();

        // With 0 staked Chirp, yield stays in principal (yieldPinto == 0, dayPinto == 0).
        assertEq(collective.siloPinto(), 150e6);
        assertEq(collective.yieldPinto(), 0);
        assertEq(collective.dayPinto(ve.currentDay()), 0);
    }

    function test_post_withdraw_claim_still_works() public {
        pinto.mint(address(collective), 500e6);
        collective.seed();

        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 2, false, coinA);

        // Day d0 + 1: plant 100 Pinto.
        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        uint32 d1 = ve.currentDay();
        silo.setBelow(false);
        silo.setPlant(100e6, 12);
        pinto.mint(PINTO_DIAMOND, 100e6);
        collective.plant();

        // Advance past lock expiry (d0 + 3) and Alice withdraws her Chirp FIRST before claiming!
        vm.warp(block.timestamp + 3 days);
        vm.prank(ALICE);
        ve.withdraw(id);

        // Now distribute d1 and Alice STILL claims her coins!
        uint32[] memory ds = new uint32[](1);
        ds[0] = d1;
        uint256 bought = collective.distribute(coinA, ds, 500e6);
        vm.prank(ALICE);
        (address c, uint256 paid) = collective.claim(id, 30);
        assertEq(c, coinA);
        assertEq(paid, bought);
    }

    function test_dust_entitled_does_not_brick_future_claims() public {
        pinto.mint(address(collective), 1_000e6);
        collective.seed();

        // Day 0: Alice locks 1 Chirp on coinA; Bob locks 100,000 Chirp on coinB.
        chirp.transfer(BOB, 100_000 ether);
        vm.prank(ALICE);
        uint256 idAlice = ve.lock(1 ether, 30, false, coinA);
        vm.prank(BOB);
        ve.lock(100_000 ether, 0, true, coinB);

        // Day 1: 100 Pinto planted -> Alice's coinA entitled is ~100e6 * 1 / 100001 < 10_000 (0.01 Pinto dust floor!).
        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        uint32 d1 = ve.currentDay();
        silo.setBelow(false);
        silo.setPlant(100e6, 20);
        pinto.mint(PINTO_DIAMOND, 100e6);
        collective.plant();

        // Alice switches to coinB for Day 2!
        vm.prank(ALICE);
        ve.switchCoin(idAlice, coinB);

        // Day 2: 500 Pinto planted on coinB.
        vm.warp(block.timestamp + 1 days);
        uint32 d2 = ve.currentDay();
        silo.setPlant(500e6, 21);
        pinto.mint(PINTO_DIAMOND, 500e6);
        collective.plant();

        // Day 3: distribute ONLY coinB for d2 (coinA d1 is NEVER distributed because it is sub-cent dust!).
        vm.warp(block.timestamp + 1 days);
        uint32[] memory ds = new uint32[](1);
        ds[0] = d2;
        collective.distribute(coinB, ds, 1_000e6);

        // Dust d1 must NOT block Alice from advancing past d1 and claiming her d2 coinB rewards!
        vm.prank(ALICE);
        (address c, uint256 pay) = collective.claim(idAlice, 30);
        assertEq(c, coinB);
        assertGt(pay, 0, "Alice claimed d2 cleanly despite sub-cent dust on d1");
        assertEq(collective.lastClaimedDay(idAlice), d2);
        assertEq(collective.coinDayPaidPinto(coinA, d1), 0);
    }

    function test_yield_stems_merge_collapses_dust_stems() public {
        pinto.mint(address(collective), 1_000e6);
        collective.seed();
        uint256 principal = collective.siloPinto();

        // Stake on 3-way split so every day leaves 1 raw Pinto rounding dust on its stem.
        vm.prank(ALICE);
        ve.lock(365 ether, 0, true, coinA);
        vm.prank(BOB);
        ve.lock(730 ether, 0, true, coinB);

        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        silo.setBelow(false);

        // Plant 6 separate finished stems (well above MERGE_ABOVE_STEMS = 3).
        for (int96 st = 30; st < 36; st++) {
            silo.setNextStem(st + 2);
            silo.setPlant(100e6, st);
            pinto.mint(PINTO_DIAMOND, 100e6);
            silo.setGerminatingStem(st + 2);
            collective.plant();
            vm.warp(block.timestamp + 1 days);
        }

        // Auto-merge inside plant() + explicit mergeYieldStems() keep _yieldStems collapsed to <= 2 stems!
        collective.mergeYieldStems();
        assertLe(collective.yieldStems().length, 1, "finished yield stems collapsed into one");
        assertEq(collective.yieldPinto(), 600e6, "zero yield Pinto lost in merge");
        assertEq(collective.siloPinto() - collective.yieldPinto(), principal, "principal untouched");
    }

    function test_partial_fill_dust_griefing_prevented() public {
        pinto.mint(address(collective), 1_000e6);
        collective.seed();

        vm.prank(ALICE);
        uint256 idAlice = ve.lock(365 ether, 0, true, coinA);

        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        uint32 d1 = ve.currentDay();
        silo.setBelow(false);
        silo.setPlant(100e6, 40);
        pinto.mint(PINTO_DIAMOND, 100e6);
        collective.plant();

        vm.warp(block.timestamp + 1 days);
        uint32[] memory ds = new uint32[](1);
        ds[0] = d1;

        // Attacker tries to leave 1 raw Pinto unpaid (entitled - 1). Contract trims take so >= MIN_DAY_ENTITLED remains!
        collective.distribute(coinA, ds, 100e6 - 1);
        uint256 paid1 = collective.coinDayPaidPinto(coinA, d1);
        assertEq(paid1, 100e6 - collective.MIN_DAY_ENTITLED(), "trimmed to leave distributable MIN_DAY_ENTITLED tail");

        // Second call cleanly distributes the exact MIN_DAY_ENTITLED tail, unblocking claim()!
        collective.distribute(coinA, ds, 100e6);
        assertEq(collective.coinDayPaidPinto(coinA, d1), 100e6);

        vm.prank(ALICE);
        (address c, uint256 pay) = collective.claim(idAlice, 30);
        assertEq(c, coinA);
        assertGt(pay, 0);
    }

    function test_multi_coin_switch_zero_day_and_unsettled_middle_day_in_claim() public {
        pinto.mint(address(collective), 1_000e6);
        collective.seed();

        // Day 0: Alice locks on coinA.
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 0, true, coinA);

        // Day 1: 100 Pinto planted on coinA.
        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        uint32 d1 = ve.currentDay();
        silo.setBelow(false);
        silo.setPlant(100e6, 50);
        pinto.mint(PINTO_DIAMOND, 100e6);
        collective.plant();
        // Switch to coinB for Day 2.
        vm.prank(ALICE);
        ve.switchCoin(id, coinB);

        // Day 2: 0 yield (below peg).
        vm.warp(block.timestamp + 1 days);

        // Day 3: 200 Pinto planted on coinB (will be left unsettled first!).
        vm.warp(block.timestamp + 1 days);
        uint32 d3 = ve.currentDay();
        silo.setPlant(200e6, 51);
        pinto.mint(PINTO_DIAMOND, 200e6);
        collective.plant();

        // Day 4: 150 Pinto planted on coinB (settled!).
        vm.warp(block.timestamp + 1 days);
        uint32 d4 = ve.currentDay();
        silo.setPlant(150e6, 52);
        pinto.mint(PINTO_DIAMOND, 150e6);
        collective.plant();

        vm.warp(block.timestamp + 1 days);
        uint32[] memory ds1 = new uint32[](1);
        ds1[0] = d1;
        collective.distribute(coinA, ds1, 1_000e6);

        uint32[] memory ds4 = new uint32[](1);
        ds4[0] = d4;
        collective.distribute(coinB, ds4, 1_000e6);

        // Claim 1: pays coinA (d1), stops at coinB (d2/d3) without skipping unsettled d3!
        vm.prank(ALICE);
        (address c1, uint256 p1) = collective.claim(id, 30);
        assertEq(c1, coinA);
        assertGt(p1, 0);
        assertEq(collective.lastClaimedDay(id), d1);

        // Claim 2: skips 0-yield d2, stops at unsettled d3 (0 payout, cursor advanced to d2!).
        vm.prank(ALICE);
        (, uint256 p2) = collective.claim(id, 30);
        assertEq(p2, 0);
        assertEq(collective.lastClaimedDay(id), d3 - 1);

        // Now distribute d3 -> Claim 3 pays BOTH d3 + d4 of coinB in one call!
        uint32[] memory ds3 = new uint32[](1);
        ds3[0] = d3;
        collective.distribute(coinB, ds3, 1_000e6);

        vm.prank(ALICE);
        (address c3, uint256 p3) = collective.claim(id, 30);
        assertEq(c3, coinB);
        assertGt(p3, 0);
        assertEq(collective.lastClaimedDay(id), d4);
    }

    function test_shared_principal_and_yield_stem_merge_preserves_principal() public {
        // Seed principal onto stem 60, then plant yield onto the EXACT same stem 60 + stems 61, 62, 63.
        silo.setNextStem(60);
        pinto.mint(address(collective), 500e6);
        collective.seed();
        assertEq(collective.stemAmount(60), 500e6);
        assertEq(collective.yieldAt(60), 0);

        vm.prank(ALICE);
        ve.lock(365 ether, 0, true, coinA);

        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        silo.setBelow(false);

        for (int96 st = 60; st < 64; st++) {
            silo.setNextStem(st + 2);
            silo.setPlant(100e6, st);
            pinto.mint(PINTO_DIAMOND, 100e6);
            silo.setGerminatingStem(st + 2);
            collective.plant();
            vm.warp(block.timestamp + 1 days);
        }

        collective.mergeYieldStems();
        assertEq(collective.yieldPinto(), 400e6);
        assertEq(collective.siloPinto(), 900e6);
        // Principal on stem 60 (500e6) must remain intact in both books and Silo!
        (uint256 dep60,) = silo.getDeposit(address(collective), PINTO, 60);
        assertGe(dep60, 500e6);
        assertEq(collective.stemAmount(60), dep60);
    }

    function test_mergeYieldStems_when_toStem_collides_with_from_stem() public {
        vm.prank(ALICE);
        ve.lock(365 ether, 0, true, coinA);

        vm.warp(block.timestamp + 1 days + TOLL_WINDOW);
        silo.setBelow(false);

        // Plant equal 100e6 on stems 70 and 72 with nextStem = 73 -> weighted average toStem = 71;
        // also plant on stem 71 so toStem (71) collides directly with from[1] (71)!
        for (int96 st = 70; st <= 72; st++) {
            silo.setPlant(100e6, st);
            pinto.mint(PINTO_DIAMOND, 100e6);
            collective.plant();
            vm.warp(block.timestamp + 1 days);
        }

        silo.setNextStem(73);
        silo.setGerminatingStem(73);
        collective.mergeYieldStems();

        int96[] memory stems = collective.yieldStems();
        assertEq(stems.length, 1, "merged into 1 unique stem even when toStem == from[1]");
        assertEq(stems[0], 71);
        assertEq(collective.yieldAt(71), 300e6);
        assertEq(collective.yieldPinto(), 300e6);
    }
}
