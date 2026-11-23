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

contract VeChirpHandler is Test {
    VeChirp public immutable ve;
    CollectiveSilo public immutable collective;
    LaunchToken public immutable chirp;
    MockSiloWithConvert public immutable silo;
    MockPinto public immutable pinto;
    address public immutable coinA;
    address public immutable coinB;

    address[3] public actors = [address(0xA11CE), address(0xB0B1), address(0xCA701)];
    uint256[] public lockIds;
    mapping(uint256 => bool) public withdrawn;
    uint32[] public plantedDays;
    mapping(uint32 => bool) public isPlantedDay;

    uint256 public ghostActiveLocked;
    uint256 public ghostMinPrincipal;
    uint256 public ghostBoughtA;
    uint256 public ghostBoughtB;
    uint256 public ghostClaimedA;
    uint256 public ghostClaimedB;
    int96 public nextStem = 100;

    constructor(
        VeChirp ve_,
        CollectiveSilo collective_,
        LaunchToken chirp_,
        address coinA_,
        address coinB_
    ) {
        ve = ve_;
        collective = collective_;
        chirp = chirp_;
        silo = MockSiloWithConvert(PINTO_DIAMOND);
        pinto = MockPinto(PINTO);
        coinA = coinA_;
        coinB = coinB_;
        ghostMinPrincipal = collective.siloPinto() - collective.yieldPinto();
    }

    function lockIdsLength() external view returns (uint256) {
        return lockIds.length;
    }

    function plantedDaysLength() external view returns (uint256) {
        return plantedDays.length;
    }

    function lock(uint256 actorSeed, bool pickB, uint96 rawAmt, uint16 rawDays, bool permanent) external {
        if (lockIds.length >= 24) return;
        address actor = actors[actorSeed % 3];
        uint128 amt = uint128(bound(rawAmt, 1 ether, 500 ether));
        if (chirp.balanceOf(actor) < amt) return;
        uint32 d = permanent ? 0 : uint32(bound(rawDays, 2, 365));
        address c = pickB ? coinB : coinA;
        vm.prank(actor);
        uint256 id = ve.lock(amt, d, permanent, c);
        lockIds.push(id);
        ghostActiveLocked += amt;
    }

    function addAmount(uint256 idSeed, uint96 rawAmt) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        if (withdrawn[id]) return;
        address owner = ve.ownerOf(id);
        uint128 amt = uint128(bound(rawAmt, 1 ether, 200 ether));
        if (chirp.balanceOf(owner) < amt) return;
        VeChirp.Snap memory s = ve.latestSnap(id);
        if (!s.permanent && s.endDay <= ve.currentDay() + 1) return;
        vm.prank(owner);
        ve.addAmount(id, amt);
        ghostActiveLocked += amt;
    }

    function extend(uint256 idSeed, uint16 rawDays) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        if (withdrawn[id]) return;
        VeChirp.Snap memory s = ve.latestSnap(id);
        if (s.permanent) return;
        uint32 eff = ve.currentDay() + 1;
        uint32 minEnd = s.endDay + 1 > eff + 2 ? s.endDay + 1 : eff + 2;
        uint32 maxEnd = eff + 365;
        if (minEnd > maxEnd) return;
        uint32 newEnd = uint32(bound(rawDays, minEnd, maxEnd));
        vm.prank(ve.ownerOf(id));
        ve.extend(id, newEnd);
    }

    function setPermanent(uint256 idSeed, bool on) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        if (withdrawn[id]) return;
        vm.prank(ve.ownerOf(id));
        ve.setPermanent(id, on);
    }

    function switchCoin(uint256 idSeed, bool pickB) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        if (withdrawn[id]) return;
        VeChirp.Snap memory s = ve.latestSnap(id);
        address target = pickB ? coinB : coinA;
        if (s.coin == target) return;
        if (!s.permanent && s.endDay <= ve.currentDay() + 1) return;
        vm.prank(ve.ownerOf(id));
        ve.switchCoin(id, target);
    }

    function transferNft(uint256 idSeed, uint256 toSeed) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        if (withdrawn[id]) return;
        address from = ve.ownerOf(id);
        address to = actors[toSeed % 3];
        if (from == to) return;
        vm.prank(from);
        ve.transferFrom(from, to, id);
    }

    function withdraw(uint256 idSeed) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        if (withdrawn[id]) return;
        VeChirp.Snap memory s = ve.latestSnap(id);
        if (s.permanent || ve.currentDay() < s.endDay) return;
        vm.prank(ve.ownerOf(id));
        ve.withdraw(id);
        withdrawn[id] = true;
        ghostActiveLocked -= s.amount;
    }

    function warp(uint8 stepDays) external {
        uint256 step = bound(stepDays, 1, 20);
        vm.warp(block.timestamp + step * 1 days);
    }

    function seedPinto(uint64 rawAmt) external {
        uint256 amt = bound(rawAmt, 10e6, 500e6);
        pinto.mint(address(collective), amt);
        collective.seed();
        ghostMinPrincipal += amt;
    }

    function plant(uint64 rawBeans, bool abovePeg) external {
        silo.setBelow(!abovePeg);
        uint256 beans = bound(rawBeans, 1e6, 200e6);
        nextStem += 1;
        silo.setNextStem(nextStem + 2);
        silo.setGerminatingStem(nextStem + 1);
        silo.setPlant(beans, nextStem);
        pinto.mint(PINTO_DIAMOND, beans);
        uint256 planted = collective.plant();
        if (planted > 0) {
            uint32 d = ve.currentDay();
            if (collective.dayPinto(d) == 0) {
                // 0-staker day rolled into principal
                ghostMinPrincipal += planted;
            } else if (!isPlantedDay[d]) {
                isPlantedDay[d] = true;
                plantedDays.push(d);
            }
        }
    }

    function mergeYieldStems() external {
        silo.setNextStem(nextStem + 3);
        silo.setGerminatingStem(nextStem + 2);
        try collective.mergeYieldStems() {} catch {}
    }

    function checkpoint(uint32 maxDays) external {
        ve.checkpoint(maxDays);
        ve.checkpointCoin(coinA, maxDays);
        ve.checkpointCoin(coinB, maxDays);
    }

    function distribute(bool pickB, uint64 rawMax) external {
        uint32 today = ve.currentDay();
        address coin = pickB ? coinB : coinA;
        // Collect up to 4 strictly ascending past planted days.
        uint32[] memory buf = new uint32[](4);
        uint256 count;
        for (uint256 i; i < plantedDays.length && count < 4; i++) {
            uint32 d = plantedDays[i];
            if (d < today) {
                buf[count++] = d;
            }
        }
        if (count == 0) return;
        uint32[] memory ds = new uint32[](count);
        for (uint256 i; i < count; i++) {
            ds[i] = buf[i];
        }
        uint256 maxP = bound(rawMax, 1e6, 500e6);
        try collective.distribute(coin, ds, maxP) returns (uint256 bought) {
            if (pickB) ghostBoughtB += bought;
            else ghostBoughtA += bought;
        } catch {}
    }

    function claim(uint256 idSeed, uint8 rawDays) external {
        if (lockIds.length == 0) return;
        uint256 id = lockIds[idSeed % lockIds.length];
        address claimant = ve.claimantOf(id);
        if (claimant == address(0)) return;
        uint32 maxD = uint32(bound(rawDays, 1, 60));
        vm.prank(claimant);
        (address c, uint256 pay) = collective.claim(id, maxD);
        if (pay > 0) {
            if (c == coinA) ghostClaimedA += pay;
            else if (c == coinB) ghostClaimedB += pay;
        }
    }
}

contract VeChirpInvariantTest is Test {
    address internal constant HOOK = address(uint160(0x2AEC | (uint256(0xB0C) << 148)));
    address internal constant SAFE = address(0x5AFE);

    VeChirp internal ve;
    CollectiveSilo internal collective;
    LaunchToken internal chirp;
    address internal coinA;
    address internal coinB;
    VeChirpHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(PINTO_DIAMOND, address(new MockSiloWithConvert()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);

        MockV3Pool(V3_WETH_CBETH_POOL).setTick(0);
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, 1e18);
        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, 1e18);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 2_000_000e6, 1_000e18);
        MockWell(CBETH_WELL).setReserves(2_000_000e6, 1_000e18);

        MockWETH(WETH).mint(SWAP_ROUTER02, 10_000 ether);
        MockCbEth(CBETH).mint(SWAP_ROUTER02, 10_000 ether);
        MockCbEth(CBETH).mint(CBETH_WELL, 10_000 ether);
        MockPinto(PINTO).mint(CBETH_WELL, 20_000_000e6);

        IPoolManager manager = new PoolManager(address(this));
        chirp = new LaunchToken("Chirp", "CHIRP", "", "", address(this));
        ve = new VeChirp(IERC20(address(chirp)), LauncherHook(HOOK), "https://surcofi.com/api/launcher/ve/");
        collective = new CollectiveSilo(manager, LauncherHook(HOOK), ve);
        LauncherFactory factory = new LauncherFactory(manager, LauncherHook(HOOK), SAFE, address(collective));
        deployCodeTo("LauncherHook.sol:LauncherHook", abi.encode(manager, address(factory), WETH), HOOK);
        MockWETH(WETH).mint(address(manager), 10_000 ether);

        vm.deal(address(this), 10 ether);
        (coinA,,) = factory.launch{value: 0.05 ether + LAUNCH_FEE}(
            LauncherFactory.Params("CoinA", "A", "", "", LauncherFactory.Mode.Burn, 100, 1000, address(0x1111))
        );
        (coinB,,) = factory.launch{value: 0.05 ether + LAUNCH_FEE}(
            LauncherFactory.Params("CoinB", "B", "", "", LauncherFactory.Mode.Burn, 100, 1000, address(0x2222))
        );

        // Advance past toll window so distribute() can execute immediately.
        vm.warp(block.timestamp + TOLL_WINDOW + 1);

        // Seed initial principal.
        MockPinto(PINTO).mint(address(collective), 1_000e6);
        collective.seed();

        handler = new VeChirpHandler(ve, collective, chirp, coinA, coinB);
        for (uint256 i; i < 3; i++) {
            address a = handler.actors(i);
            chirp.transfer(a, 50_000 ether);
            vm.prank(a);
            chirp.approve(address(ve), type(uint256).max);
        }

        targetContract(address(handler));
    }

    /// @notice VeChirp always holds 100% of active locked Chirp.
    function invariant_chirp_solvency() public view {
        assertEq(chirp.balanceOf(address(ve)), ve.totalLocked());
        assertEq(ve.totalLocked(), handler.ghostActiveLocked());
    }

    /// @notice Silo principal never shrinks (yield withdrawals never touch principal).
    function invariant_principal_never_decreases() public view {
        assertGe(collective.siloPinto(), collective.yieldPinto());
        assertGe(collective.siloPinto() - collective.yieldPinto(), handler.ghostMinPrincipal());
    }

    /// @notice Bought coin reserves always back unclaimed rewards 1:1 with zero over-claiming.
    function invariant_no_overclaim() public view {
        assertLe(handler.ghostClaimedA(), handler.ghostBoughtA());
        assertLe(handler.ghostClaimedB(), handler.ghostBoughtB());
        assertEq(IERC20(coinA).balanceOf(address(collective)), handler.ghostBoughtA() - handler.ghostClaimedA());
        assertEq(IERC20(coinB).balanceOf(address(collective)), handler.ghostBoughtB() - handler.ghostClaimedB());
    }

    /// @notice Global weight equals sum of coin weights, and bounds sum of individual lock weights.
    function invariant_weight_conservation() public {
        uint32 today = ve.currentDay();
        uint256 g = ve.totalWeightAt(today);
        uint256 wa = ve.coinWeightAt(coinA, today);
        uint256 wb = ve.coinWeightAt(coinB, today);
        // Each track divides bias by 365, so floor(biasA/365) + floor(biasB/365) <= floor((biasA+biasB)/365) by at most 1 wei.
        assertLe(wa + wb, g, "sum(coins) > global");
        assertLe(g - (wa + wb), 1, "global - sum(coins) > 1 wei");

        uint256 sumA;
        uint256 sumB;
        uint256 n = handler.lockIdsLength();
        for (uint256 i; i < n; i++) {
            (address c, uint256 w) = ve.lockStateAt(handler.lockIds(i), today);
            if (c == coinA) sumA += w;
            else if (c == coinB) sumB += w;
        }
        assertLe(sumA, wa, "sum(lockA) > coinA weight");
        assertLe(sumB, wb, "sum(lockB) > coinB weight");
        assertLe(wa - sumA, n, "coinA rounding drift > lock count");
        assertLe(wb - sumB, n, "coinB rounding drift > lock count");
        assertEq(ve.previewTotalWeightAt(today), g, "previewGlobal != stepped");
        assertEq(ve.previewCoinWeightAt(coinA, today), wa, "previewA != stepped");
        assertEq(ve.previewCoinWeightAt(coinB, today), wb, "previewB != stepped");
    }

    /// @notice Every yield stem is unique, backed 1:1 by Silo deposits, and sums to exact yieldPinto.
    function invariant_yield_stems_consistent() public view {
        int96[] memory stems = collective.yieldStems();
        uint256 sumYield;
        for (uint256 i; i < stems.length; i++) {
            int96 s = stems[i];
            for (uint256 j = i + 1; j < stems.length; j++) {
                assertTrue(s != stems[j], "duplicate yield stem");
            }
            uint256 y = collective.yieldAt(s);
            uint256 sa = collective.stemAmount(s);
            assertLe(y, sa, "yieldAt > stemAmount");
            (uint256 dep,) = MockSiloWithConvert(PINTO_DIAMOND).getDeposit(address(collective), PINTO, s);
            assertEq(dep, sa, "Silo deposit != stemAmount");
            sumYield += y;
        }
        assertEq(sumYield, collective.yieldPinto(), "sum(yieldAt) != yieldPinto");
    }
}
