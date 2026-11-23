// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPintoSilo} from "chirp/interfaces/IPintoSilo.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {LauncherFactory} from "../../src/LauncherFactory.sol";
import {LauncherHook} from "../../src/LauncherHook.sol";
import {VeChirp} from "../../src/VeChirp.sol";
import {CollectiveSilo} from "../../src/CollectiveSilo.sol";
import {IPintoPeg} from "../../src/VaultBase.sol";
import {ISiloTransfer} from "./Rehearsal.t.sol";
import {
    CHIRP,
    WETH,
    PINTO,
    PINTO_DIAMOND,
    LAUNCH_FEE,
    TOLL_WINDOW,
    EMA_WINDOW,
    TIP_BPS
} from "../../src/Constants.sol";

/// @notice End-to-end Base mainnet fork test for Deploy.s.sol + VeChirp + CollectiveSilo against the real
///         Pinto Diamond (Silo + LAMBDA_LAMBDA convert), cbETH Well, v3 WETH/cbETH pool, and Uniswap v4 PoolManager.
contract CollectiveSiloForkTest is Test {
    uint256 internal constant FORK_BLOCK = 60_050_000;
    address internal constant SAFE = address(0x5AFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B1);
    address internal constant KEEPER = address(0x4EE9E4);
    IPintoSilo internal constant SILO = IPintoSilo(PINTO_DIAMOND);

    LauncherHook internal hook;
    LauncherFactory internal factory;
    VeChirp internal ve;
    CollectiveSilo internal collective;
    address internal coinA;
    address internal coinB;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        (hook, factory, ve, collective) = new Deploy().deploy(SAFE);

        vm.deal(address(this), 20 ether);
        (coinA,,) = factory.launch{value: 1 ether + LAUNCH_FEE}(
            LauncherFactory.Params("ForkA", "FA", "", "", LauncherFactory.Mode.Burn, 100, 1000, ALICE)
        );
        (coinB,,) = factory.launch{value: 1 ether + LAUNCH_FEE}(
            LauncherFactory.Params("ForkB", "FB", "", "", LauncherFactory.Mode.Burn, 100, 1000, BOB)
        );

        deal(CHIRP, ALICE, 10_000 ether);
        deal(CHIRP, BOB, 10_000 ether);
        vm.prank(ALICE);
        IERC20(CHIRP).approve(address(ve), type(uint256).max);
        vm.prank(BOB);
        IERC20(CHIRP).approve(address(ve), type(uint256).max);
    }

    function _standInYield(int96 stem, uint256 beans) internal {
        address donor = address(uint160(uint256(keccak256(abi.encode("donor", stem, beans)))));
        deal(PINTO, donor, beans);
        vm.startPrank(donor);
        IERC20(PINTO).approve(PINTO_DIAMOND, beans);
        (,, int96 actualStem) = SILO.deposit(PINTO, beans, 0);
        ISiloTransfer(PINTO_DIAMOND).transferDeposit(donor, address(collective), PINTO, actualStem, beans);
        vm.stopPrank();
        vm.mockCall(PINTO_DIAMOND, abi.encodeCall(IPintoSilo.plant, ()), abi.encode(beans, actualStem));
        vm.mockCall(PINTO_DIAMOND, abi.encodeCall(IPintoPeg.abovePeg, ()), abi.encode(true));
    }

    function test_fork_launch_fees_convert_seed_plant_distribute_and_claim() public {
        // Two launches funded CollectiveSilo with 2 * LAUNCH_FEE WETH.
        assertEq(IERC20(WETH).balanceOf(address(collective)), 2 * LAUNCH_FEE);

        // Convert launch fees on real Base v3 WETH/cbETH + Basin cbETH/Pinto well -> real Pinto Silo.
        vm.prank(KEEPER);
        collective.convert();
        assertGt(collective.siloPinto(), 0, "launch fees converted into real Silo Pinto");
        assertEq(IERC20(WETH).balanceOf(address(collective)), 0);

        // Voluntary seed() on real Pinto Silo.
        deal(PINTO, address(collective), 500e6);
        collective.seed();
        uint256 principal = collective.siloPinto();
        assertGt(principal, 500e6);

        // Alice locks 365 CHIRP permanently on coinA; Bob locks 365 CHIRP for 365d on coinB.
        vm.prank(ALICE);
        uint256 idAlice = ve.lock(365 ether, 0, true, coinA);
        vm.prank(BOB);
        uint256 idBob = ve.lock(365 ether, 365, false, coinB);

        // Advance to next UTC day + past toll + EMA window.
        vm.warp(block.timestamp + 1 days + TOLL_WINDOW + EMA_WINDOW);
        uint32 d1 = ve.currentDay();
        assertEq(ve.previewTotalWeightAt(d1), 730 ether);

        // Plant 400 Pinto stand-in yield on the real Silo stem (shared with principal!).
        int96 stem = SILO.stemTipForToken(PINTO);
        _standInYield(stem, 400e6);
        uint256 planted = collective.plant();
        vm.clearMockedCalls();
        assertEq(planted, 400e6);
        assertEq(collective.dayPinto(d1), 400e6);

        // Advance to d2 so d1 is finalized, then distribute coinA (200 Pinto) and coinB (200 Pinto) on real v4 pools!
        vm.warp(block.timestamp + 1 days);
        uint32[] memory ds = new uint32[](1);
        ds[0] = d1;

        uint256 aliceCoinBefore = IERC20(coinA).balanceOf(ALICE);
        uint256 bobCoinBefore = IERC20(coinB).balanceOf(BOB);

        vm.prank(KEEPER);
        uint256 boughtA = collective.distribute(coinA, ds, 1_000e6);
        assertGt(boughtA, 0, "real v4 swap bought coinA");

        // Let cbETH well EMA settle slightly before second distribute.
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 150);

        vm.prank(KEEPER);
        uint256 boughtB = collective.distribute(coinB, ds, 1_000e6);
        assertGt(boughtB, 0, "real v4 swap bought coinB");

        // Keeper received 0.5% Pinto tip on both 200-Pinto batches; principal untouched in real Silo!
        assertEq(IERC20(PINTO).balanceOf(KEEPER), 400e6 * TIP_BPS / 1e4);
        assertEq(collective.siloPinto(), principal, "real Silo principal untouched");
        assertEq(collective.yieldPinto(), 0);
        (uint256 dep,) = SILO.getDeposit(address(collective), PINTO, stem);
        assertEq(dep, principal, "real Silo deposit matches books");

        // Alice and Bob each claim 100% of their bought coins!
        vm.prank(ALICE);
        (address cA, uint256 payA) = collective.claim(idAlice, 30);
        assertEq(cA, coinA);
        assertEq(payA, boughtA);
        assertEq(IERC20(coinA).balanceOf(ALICE) - aliceCoinBefore, boughtA);

        vm.prank(BOB);
        (address cB, uint256 payB) = collective.claim(idBob, 30);
        assertEq(cB, coinB);
        assertEq(payB, boughtB);
        assertEq(IERC20(coinB).balanceOf(BOB) - bobCoinBefore, boughtB);
    }
}
