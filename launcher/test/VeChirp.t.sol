// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {MockWETH} from "./mocks/LauncherMocks.sol";
import {LauncherFactory} from "../src/LauncherFactory.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {VeChirp} from "../src/VeChirp.sol";
import {WETH, LAUNCH_FEE} from "../src/Constants.sol";

contract VeChirpTest is Test {
    address internal constant HOOK = address(uint160(0x2AEC | (uint256(0xB0B) << 148)));
    address internal constant SAFE = address(0x5AFE);
    address internal constant COLLECTIVE = address(0xC011EC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B1);

    IPoolManager internal manager;
    LauncherFactory internal factory;
    LauncherHook internal hook;
    LaunchToken internal chirp;
    VeChirp internal ve;
    address internal coinA;
    address internal coinB;

    function setUp() public {
        vm.warp(1_800_000_000); // clean non-zero UTC day
        vm.etch(WETH, address(new MockWETH()).code);
        manager = new PoolManager(address(this));
        factory = new LauncherFactory(manager, LauncherHook(HOOK), SAFE, COLLECTIVE);
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(factory), WETH), HOOK);
        hook = LauncherHook(HOOK);

        chirp = new LaunchToken("Chirp", "CHIRP", "", "", address(this));
        ve = new VeChirp(IERC20(address(chirp)), hook, "https://surcofi.com/api/launcher/ve/");

        vm.deal(address(this), 10 ether);
        (coinA,,) = factory.launch{value: LAUNCH_FEE}(
            LauncherFactory.Params("CoinA", "A", "", "", LauncherFactory.Mode.Burn, 100, 1000, ALICE)
        );
        (coinB,,) = factory.launch{value: LAUNCH_FEE}(
            LauncherFactory.Params("CoinB", "B", "", "", LauncherFactory.Mode.Burn, 100, 1000, BOB)
        );

        chirp.transfer(ALICE, 10_000 ether);
        chirp.transfer(BOB, 10_000 ether);
        vm.prank(ALICE);
        chirp.approve(address(ve), type(uint256).max);
        vm.prank(BOB);
        chirp.approve(address(ve), type(uint256).max);
    }

    function test_linear_decay_2d_to_365d_exact_zero_drift() public {
        uint32 d0 = ve.currentDay();
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 365, false, coinA);
        assertEq(ve.ownerOf(id), ALICE);
        assertEq(ve.tokenURI(id), "https://surcofi.com/api/launcher/ve/1");

        // Today (d0) weight is still 0 (takes effect tomorrow = d0 + 1).
        assertEq(ve.totalWeightAt(d0), 0);
        assertEq(ve.coinWeightAt(coinA, d0), 0);

        // Day d0 + 1: 100% weight (365 ether).
        vm.warp(block.timestamp + 1 days);
        assertEq(ve.totalWeightAt(d0 + 1), 365 ether);
        assertEq(ve.coinWeightAt(coinA, d0 + 1), 365 ether);

        // Halfway (182 days later): remaining = 183 days -> 183 ether exact.
        vm.warp(block.timestamp + 182 days);
        assertEq(ve.totalWeightAt(d0 + 183), 183 ether);
        assertEq(ve.coinWeightAt(coinA, d0 + 183), 183 ether);
        (, uint256 lw) = ve.lockStateAt(id, d0 + 183);
        assertEq(lw, 183 ether);

        // Expiry (d0 + 366): weight drops cleanly to EXACTLY 0, withdrawable.
        vm.warp(block.timestamp + 183 days);
        assertEq(ve.totalWeightAt(d0 + 366), 0);
        assertEq(ve.coinWeightAt(coinA, d0 + 366), 0);

        uint256 before = chirp.balanceOf(ALICE);
        vm.prank(ALICE);
        ve.withdraw(id);
        assertEq(chirp.balanceOf(ALICE) - before, 365 ether);
        assertEq(ve.totalLocked(), 0);
        assertEq(ve.claimantOf(id), ALICE, "post-withdraw claimant preserved");
    }

    function test_2day_minimum_and_bounds() public {
        vm.startPrank(ALICE);
        vm.expectRevert(VeChirp.BadDuration.selector);
        ve.lock(100 ether, 1, false, coinA);
        vm.expectRevert(VeChirp.BadDuration.selector);
        ve.lock(100 ether, 366, false, coinA);
        vm.expectRevert(VeChirp.UnknownCoin.selector);
        ve.lock(100 ether, 2, false, address(0x1234));

        uint32 d0 = ve.currentDay();
        uint256 id = ve.lock(365 ether, 2, false, coinA);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        assertEq(ve.totalWeightAt(d0 + 1), 2 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(ve.totalWeightAt(d0 + 2), 1 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(ve.totalWeightAt(d0 + 3), 0);

        vm.prank(ALICE);
        ve.withdraw(id);
        assertEq(ve.totalLocked(), 0);
    }

    function test_permanent_toggle_and_unlock_countdown() public {
        uint32 d0 = ve.currentDay();
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 0, true, coinA);

        // Stays 100% weight after 500 days!
        vm.warp(block.timestamp + 500 days);
        uint32 d500 = ve.currentDay();
        assertEq(d500, d0 + 500);
        assertEq(ve.totalWeightAt(d500), 365 ether);
        assertEq(ve.coinWeightAt(coinA, d500), 365 ether);

        // Cannot withdraw while permanent.
        vm.expectRevert(VeChirp.StillLocked.selector);
        vm.prank(ALICE);
        ve.withdraw(id);

        // Toggle permanent off -> starts 365-day countdown from tomorrow (d500 + 1).
        vm.prank(ALICE);
        ve.setPermanent(id, false);
        vm.warp(block.timestamp + 1 days);
        assertEq(ve.totalWeightAt(d500 + 1), 365 ether);
        vm.warp(block.timestamp + 10 days);
        assertEq(ve.totalWeightAt(d500 + 11), 355 ether);

        // Wait until expiry (355 more days).
        vm.warp(block.timestamp + 355 days);
        assertEq(ve.totalWeightAt(d500 + 366), 0);
        vm.prank(ALICE);
        ve.withdraw(id);
    }

    function test_same_day_multiple_edits_and_coin_switch() public {
        uint32 d0 = ve.currentDay();
        vm.startPrank(ALICE);
        uint256 id = ve.lock(365 ether, 10, false, coinA);
        ve.addAmount(id, 365 ether); // now 730 ether
        ve.switchCoin(id, coinB); // moved to coinB on same day d0
        ve.extend(id, d0 + 1 + 20); // extended to 20 days on same day d0
        vm.stopPrank();

        assertEq(ve.snapCount(id), 1, "same-day mutations collapse into 1 snap");
        vm.warp(block.timestamp + 1 days);
        assertEq(ve.coinWeightAt(coinA, d0 + 1), 0, "coinA cancelled cleanly to 0");
        assertEq(ve.coinWeightAt(coinB, d0 + 1), 40 ether, "730 * 20 / 365 = 40");
        assertEq(ve.totalWeightAt(d0 + 1), 40 ether);

        // Switch back to coinA on day d0 + 1 -> takes effect on d0 + 2 (today frozen!)
        vm.prank(ALICE);
        ve.switchCoin(id, coinA);
        assertEq(ve.coinWeightAt(coinB, d0 + 1), 40 ether, "today stays frozen");
        assertEq(ve.coinWeightAt(coinA, d0 + 1), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(ve.coinWeightAt(coinB, d0 + 2), 0);
        assertEq(ve.coinWeightAt(coinA, d0 + 2), 38 ether, "730 * 19 / 365 = 38");
    }

    function test_venft_transfer_moves_control_cleanly() public {
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 5, false, coinA);

        vm.prank(ALICE);
        ve.transferFrom(ALICE, BOB, id);
        assertEq(ve.ownerOf(id), BOB);
        assertEq(ve.claimantOf(id), BOB);

        vm.expectRevert(VeChirp.NotOwner.selector);
        vm.prank(ALICE);
        ve.switchCoin(id, coinB);

        vm.prank(BOB);
        ve.switchCoin(id, coinB);
    }

    function testFuzz_global_equals_sum_of_coins(uint64 amtA, uint64 amtB, uint16 daysA, uint16 daysB, bool permB) public {
        uint128 a = uint128(bound(amtA, 1e18, 1_000 ether));
        uint128 b = uint128(bound(amtB, 1e18, 1_000 ether));
        uint32 dA = uint32(bound(daysA, 2, 365));
        uint32 dB = uint32(bound(daysB, 2, 365));

        uint32 d0 = ve.currentDay();
        vm.prank(ALICE);
        uint256 idA = ve.lock(a, dA, false, coinA);
        vm.prank(BOB);
        uint256 idB = ve.lock(b, dB, permB, coinB);

        // Check 3 checkpoints across the lock lifetimes.
        uint32[3] memory offsets = [uint32(1), dA / 2 + 1, dA + 2];
        for (uint256 i; i < 3; i++) {
            uint32 target = d0 + offsets[i];
            vm.warp(uint256(target) * 1 days + 12 hours);
            uint256 tw = ve.totalWeightAt(target);
            uint256 wA = ve.coinWeightAt(coinA, target);
            uint256 wB = ve.coinWeightAt(coinB, target);
            (, uint256 lA) = ve.lockStateAt(idA, target);
            (, uint256 lB) = ve.lockStateAt(idB, target);
            assertEq(wA, lA, "coinA == lockA");
            assertEq(wB, lB, "coinB == lockB");
            // Global bias = biasA + biasB, so floor((biasA+biasB)/365) >= floor(biasA/365) + floor(biasB/365) by at most 1 wei.
            assertGe(tw, wA + wB);
            assertLe(tw - (wA + wB), 1);
        }
    }

    function test_preview_weights_match_after_midnight_before_stepping() public {
        vm.prank(ALICE);
        ve.lock(365 ether, 10, false, coinA);
        uint32 d0 = ve.currentDay();

        // Warp 3 days forward WITHOUT calling any state-changing tx on VeChirp!
        vm.warp(block.timestamp + 3 days);
        uint32 d3 = ve.currentDay();
        assertEq(d3, d0 + 3);

        // viewCoinWeightAt returns 0 before stepping, while preview* returns the exact decayed weight (8 days left).
        assertEq(ve.viewCoinWeightAt(coinA, d3), 0);
        assertEq(ve.previewTotalWeightAt(d3), 8 ether);
        assertEq(ve.previewCoinWeightAt(coinA, d3), 8 ether);

        // After stepping, preview* and stepped weightAt match identically.
        assertEq(ve.totalWeightAt(d3), ve.previewTotalWeightAt(d3));
        assertEq(ve.coinWeightAt(coinA, d3), ve.previewCoinWeightAt(coinA, d3));
    }

    function test_dust_lock_reverts_and_checkpoint_max_uint32_safe() public {
        vm.prank(ALICE);
        vm.expectRevert(VeChirp.ZeroAmount.selector);
        ve.lock(364, 2, false, coinA);

        // Minimum valid amount (365 wei) produces non-zero weight on every active day.
        vm.prank(ALICE);
        uint256 id = ve.lock(365, 2, false, coinA);
        uint32 d1 = ve.currentDay() + 1;
        vm.warp(block.timestamp + 1 days);
        (, uint256 lw) = ve.lockStateAt(id, d1);
        assertEq(lw, 2);

        // checkpoint(type(uint32).max) and checkpointCoin(coin, type(uint32).max) never overflow uint32.
        vm.warp(block.timestamp + 5 days);
        uint32 today = ve.currentDay();
        assertEq(ve.checkpoint(type(uint32).max), today);
        assertEq(ve.checkpointCoin(coinA, type(uint32).max), today);
    }

    function test_boundary_endDay_eq_eff_and_relock_after_expiry() public {
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 2, false, coinA); // fromDay = d0+1, endDay = d0+3
        uint32 d0 = ve.currentDay();

        // Advance to d0 + 2 -> eff = d0 + 3 == endDay!
        vm.warp(block.timestamp + 2 days);
        assertEq(ve.currentDay(), d0 + 2);

        // addAmount and switchCoin must revert BadDuration because endDay <= eff.
        vm.startPrank(ALICE);
        vm.expectRevert(VeChirp.BadDuration.selector);
        ve.addAmount(id, 10 ether);
        vm.expectRevert(VeChirp.BadDuration.selector);
        ve.switchCoin(id, coinB);
        vm.stopPrank();

        // Advance past expiry (d0 + 5): lock is expired (weight 0), NOT withdrawn -> Alice can re-lock via setPermanent(true).
        vm.warp(block.timestamp + 3 days);
        uint32 d5 = ve.currentDay();
        assertEq(ve.totalWeightAt(d5), 0);

        vm.prank(ALICE);
        ve.setPermanent(id, true);

        // Cannot withdraw while permanently re-locked!
        vm.prank(ALICE);
        vm.expectRevert(VeChirp.StillLocked.selector);
        ve.withdraw(id);

        // Next day (d0 + 6): full 365 ether weight active again, historical d0 + 5 stays 0!
        vm.warp(block.timestamp + 1 days);
        uint32 d6 = ve.currentDay();
        assertEq(ve.totalWeightAt(d5), 0);
        assertEq(ve.totalWeightAt(d6), 365 ether);
        assertEq(ve.coinWeightAt(coinA, d6), 365 ether);
    }

    function test_extend_expired_lock_reactivates_cleanly() public {
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 2, false, coinA); // fromDay = d0+1, endDay = d0+3
        uint32 d0 = ve.currentDay();

        // Warp to d0 + 4 (expired for 2 days).
        vm.warp(block.timestamp + 4 days);
        uint32 d4 = ve.currentDay();
        assertEq(ve.totalWeightAt(d4), 0);

        // Extend expired lock directly for 10 days from tomorrow (d0 + 5 .. d0 + 15).
        uint32 eff = d4 + 1;
        vm.prank(ALICE);
        ve.extend(id, eff + 10);

        // Next day (d0 + 5): weight = 10 ether, while expired gap days d0 + 3 and d0 + 4 remain 0!
        vm.warp(block.timestamp + 1 days);
        assertEq(ve.totalWeightAt(d0 + 3), 0);
        assertEq(ve.totalWeightAt(d0 + 4), 0);
        assertEq(ve.totalWeightAt(eff), 10 ether);
        (, uint256 lw5) = ve.lockStateAt(id, eff);
        assertEq(lw5, 10 ether);

        // Warp to eff + 10 -> decays back to 0 cleanly with zero underflow!
        vm.warp(block.timestamp + 11 days);
        assertEq(ve.totalWeightAt(eff + 10), 0);
        assertEq(ve.totalWeightAt(eff + 11), 0);
    }

    function test_same_day_setPermanent_roundtrip_cancels_deltas() public {
        vm.prank(ALICE);
        uint256 id = ve.lock(365 ether, 0, true, coinA);

        vm.warp(block.timestamp + 1 days);
        uint32 d1 = ve.currentDay();
        assertEq(ve.totalWeightAt(d1), 365 ether);

        // Toggle permanent off and back on during the same day d1 -> net slope/bias delta at d1 + 1 and d1 + 366 is 0!
        vm.startPrank(ALICE);
        ve.setPermanent(id, false);
        ve.setPermanent(id, true);
        vm.stopPrank();

        // Step across 370 days (past the cancelled d1 + 366 endDay) and confirm weight stays 365 ether with no underflow!
        vm.warp(block.timestamp + 370 days);
        uint32 d371 = ve.currentDay();
        assertEq(ve.totalWeightAt(d371), 365 ether);
        assertEq(ve.coinWeightAt(coinA, d371), 365 ether);
    }
}
