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
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeMath} from "../src/FeeMath.sol";
import {
    WETH,
    CBETH,
    PINTO,
    PINTO_DIAMOND,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    V3_WETH_CBETH_POOL,
    SWAP_ROUTER02,
    MAX_CREATOR_BPS
} from "../src/Constants.sol";

/// The smallest concrete vault: VaultBase plus a handle on _withdraw.
contract TestVault is VaultBase {
    uint256 public afterConvertCalls;

    constructor(LaunchToken coin, address safe, address creatorPayout, uint16 creatorBps)
        VaultBase(coin, safe, creatorPayout, creatorBps)
    {}

    function withdraw(uint256 amount) external {
        _withdraw(amount);
    }

    function stemCount() external view returns (uint256) {
        return _stems.length;
    }

    function _afterConvert() internal override {
        afterConvertCalls++;
    }
}

contract VaultBaseTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant CREATOR = address(0xC0FFEE);
    address constant KEEPER = address(0xBEEF);

    MockSiloWithConvert silo = MockSiloWithConvert(PINTO_DIAMOND);
    MockWETH weth = MockWETH(WETH);
    LaunchToken coin;
    TestVault vault;

    function setUp() public {
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);
        vm.etch(PINTO_DIAMOND, address(new MockSiloWithConvert()).code);

        // Same market as PintoRouteMockTest: 690k Pinto / 6.5 cbETH, spot = EMA, router spot = TWAP.
        MockWell(CBETH_WELL).setReserves(690_000e6, 6.5 ether);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 690_000e6, 6.5 ether);
        MockPinto(PINTO).mint(CBETH_WELL, 690_000e6);
        MockCbEth(CBETH).mint(CBETH_WELL, 6.5 ether);
        MockV3Pool(V3_WETH_CBETH_POOL).setTick(1345);
        RouteHarness h = new RouteHarness();
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, h.cbEthForWeth(1 ether));
        MockCbEth(CBETH).mint(SWAP_ROUTER02, 100 ether);

        coin = new LaunchToken("Coin", "COIN", "", "", address(this));
        vault = new TestVault(coin, SAFE, CREATOR, uint16(MAX_CREATOR_BPS));
    }

    /// Time passes and the pump's EMA reaches the well's spot. Each 0.05 WETH convert moves the well's price ~1.4%,
    /// past WELL_TOL_BPS, so a second convert against a stale EMA would revert (as it would on chain).
    function _emaCatchesUp() internal {
        uint256[] memory r = MockWell(CBETH_WELL).getReserves();
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, r[0], r[1]);
    }

    function _vault(uint16 creatorBps) internal returns (TestVault) {
        return new TestVault(coin, SAFE, CREATOR, creatorBps);
    }

    function testFuzz_split_accounts_exactly(uint256 fees, uint16 creatorBps) public {
        fees = bound(fees, 0, 1_000_000 ether);
        creatorBps = uint16(bound(creatorBps, 0, MAX_CREATOR_BPS));
        TestVault v = _vault(creatorBps);
        weth.mint(address(v), fees);

        v.split();

        (uint256 platform, uint256 creator, uint256 pinto) = FeeMath.split(fees, creatorBps);
        assertEq(weth.balanceOf(SAFE), platform);
        assertEq(weth.balanceOf(CREATOR), creator);
        assertEq(v.pendingPintoWeth(), pinto);
        assertEq(weth.balanceOf(SAFE) + weth.balanceOf(CREATOR) + v.pendingPintoWeth(), fees);
        assertEq(weth.balanceOf(address(v)), v.pendingPintoWeth());
    }

    function test_split_twice_pays_once() public {
        weth.mint(address(vault), 1 ether);
        vault.split();
        vault.split();
        assertEq(weth.balanceOf(SAFE), 0.2 ether);
        assertEq(weth.balanceOf(CREATOR), 0.2 ether);
        assertEq(vault.pendingPintoWeth(), 0.6 ether);

        // A later fee is split on its own, the pending portion is not split again.
        weth.mint(address(vault), 1 ether);
        vault.split();
        assertEq(weth.balanceOf(SAFE), 0.4 ether);
        assertEq(weth.balanceOf(CREATOR), 0.4 ether);
        assertEq(vault.pendingPintoWeth(), 1.2 ether);
    }

    function test_convert_caps_batch() public {
        TestVault v = _vault(0);
        weth.mint(address(v), 0.25 ether); // 0.05 platform, 0.2 Pinto portion

        vm.prank(KEEPER);
        v.convert();

        assertEq(v.pendingPintoWeth(), 0.15 ether);
        assertEq(weth.balanceOf(address(v)), 0.15 ether);
        assertEq(weth.balanceOf(SAFE), 0.05 ether);
        assertGt(v.siloPinto(), 0);
        assertEq(v.afterConvertCalls(), 1);
    }

    function test_convert_tip_to_caller() public {
        weth.mint(address(vault), 0.05 ether); // 0.03 Pinto portion, under the cap
        uint256 tip = FeeMath.tip(0.03 ether);
        uint256 routed = 0.03 ether - tip;
        uint256 pintoOut = MockWell(CBETH_WELL)
            .getSwapOut(CBETH, PINTO, routed * MockSwapRouter(SWAP_ROUTER02).rate(WETH, CBETH) / 1e18);

        vm.expectEmit(address(vault));
        emit VaultBase.Converted(routed, pintoOut, tip);
        vm.prank(KEEPER);
        vault.convert();

        assertEq(tip, 0.00015 ether);
        assertEq(weth.balanceOf(KEEPER), tip);
        assertEq(vault.pendingPintoWeth(), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(vault.siloPinto(), pintoOut);
        assertEq(MockPinto(PINTO).balanceOf(address(vault)), 0);
    }

    /// Dust that buys no Pinto reverts instead of spending the WETH for nothing.
    function test_convert_dust_zero_out_reverts() public {
        weth.mint(address(vault), 2);
        vm.expectRevert(VaultBase.ZeroOut.selector);
        vault.convert();
    }

    /// A Silo that re-enters split() mid-convert (batch already off pendingPintoWeth, tip still in the balance)
    /// would pay the batch out as a fee. The lock refuses it.
    function test_reentrant_split_reverts() public {
        weth.mint(address(vault), 1 ether);
        silo.setReenter(address(vault), abi.encodeCall(VaultBase.split, ()));
        vm.expectRevert(VaultBase.Locked.selector);
        vault.convert();
    }

    function test_reentrant_convert_reverts() public {
        weth.mint(address(vault), 1 ether);
        silo.setReenter(address(vault), abi.encodeCall(VaultBase.convert, ()));
        vm.expectRevert(VaultBase.Locked.selector);
        vault.convert();

        // The lock clears with the call: once the Silo behaves, split and convert run again in one transaction.
        silo.setReenter(address(0), "");
        vault.convert();
        vault.split();
        assertEq(vault.pendingPintoWeth(), 0.55 ether);
    }

    function test_convert_nothing_pending_reverts() public {
        vm.expectRevert(VaultBase.NothingPending.selector);
        vault.convert();
    }

    /// Review Focus 5: well spot 5% off the pump EMA → convert reverts whole; split alone still pays.
    function test_convert_guard_revert_keeps_pending() public {
        weth.mint(address(vault), 1 ether);
        MockWell(CBETH_WELL).setReserves(655_500e6, 6.5 ether);

        vm.expectPartialRevert(MockWell.SlippageOut.selector);
        vm.prank(KEEPER);
        vault.convert();

        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(weth.balanceOf(KEEPER), 0);
        assertEq(vault.siloPinto(), 0);

        vault.split();
        assertEq(weth.balanceOf(SAFE), 0.2 ether);
        assertEq(weth.balanceOf(CREATOR), 0.2 ether);
        assertEq(vault.pendingPintoWeth(), 0.6 ether);

        // The well recovers: the waiting WETH converts.
        MockWell(CBETH_WELL).setReserves(690_000e6, 6.5 ether);
        vault.convert();
        assertEq(vault.pendingPintoWeth(), 0.55 ether);
    }

    function test_creator_payout_rotation() public {
        address next = address(0xA11CE);

        vm.expectRevert(VaultBase.OnlyCreator.selector);
        vault.setCreatorPayout(next);

        vm.expectEmit(address(vault));
        emit VaultBase.CreatorPayoutChanged(CREATOR, next);
        vm.prank(CREATOR);
        vault.setCreatorPayout(next);
        assertEq(vault.creatorPayout(), next);

        // The old address can no longer rotate it, and gets nothing from later fees.
        vm.expectRevert(VaultBase.OnlyCreator.selector);
        vm.prank(CREATOR);
        vault.setCreatorPayout(CREATOR);

        weth.mint(address(vault), 1 ether);
        vault.split();
        assertEq(weth.balanceOf(CREATOR), 0);
        assertEq(weth.balanceOf(next), 0.2 ether);
    }

    function test_payout_zero_reverts() public {
        vm.expectRevert(VaultBase.ZeroAddress.selector);
        vm.prank(CREATOR);
        vault.setCreatorPayout(address(0));

        vm.expectRevert(VaultBase.ZeroAddress.selector);
        new TestVault(coin, SAFE, address(0), 0);
        vm.expectRevert(VaultBase.ZeroAddress.selector);
        new TestVault(coin, address(0), CREATOR, 0);
        vm.expectRevert(VaultBase.ZeroAddress.selector);
        new TestVault(LaunchToken(address(0)), SAFE, CREATOR, 0);
    }

    function test_creator_bps_over_max_reverts() public {
        vm.expectRevert(VaultBase.CreatorBps.selector);
        new TestVault(coin, SAFE, CREATOR, uint16(MAX_CREATOR_BPS + 1));
    }

    function test_factory_is_deployer() public view {
        assertEq(vault.factory(), address(this));
    }

    /// Two converts in one season land on one stem: one entry, amounts summed.
    function test_same_stem_deposits_merge() public {
        silo.setNextStem(7);
        weth.mint(address(vault), 0.05 ether);
        vault.convert();
        uint256 first = vault.siloPinto();
        _emaCatchesUp();
        weth.mint(address(vault), 0.05 ether);
        vault.convert();

        assertEq(vault.stemCount(), 1);
        assertGt(vault.siloPinto(), first);
        assertEq(vault.stemAmount(7), vault.siloPinto());
        assertEq(silo.deposits(address(vault), 7), vault.siloPinto());
        assertEq(vault.siloPinto(), silo.held(address(vault)));
    }

    /// Deposits on three stems, then LIFO withdrawals: the tally always equals what the Silo holds for the vault.
    function test_silo_tally_matches_deposits() public {
        for (int96 stem = 1; stem <= 3; stem++) {
            silo.setNextStem(stem);
            weth.mint(address(vault), 0.05 ether);
            vault.convert();
            assertEq(vault.siloPinto(), silo.held(address(vault)));
            _emaCatchesUp();
        }
        uint256 s1 = silo.deposits(address(vault), 1);
        uint256 s2 = silo.deposits(address(vault), 2);
        uint256 s3 = silo.deposits(address(vault), 3);
        assertEq(vault.siloPinto(), s1 + s2 + s3);
        assertEq(vault.stemAmount(3), s3);

        // Newest first: all of stem 3, then part of stem 2; stem 1 untouched.
        uint256 amount = s3 + s2 / 2;
        vault.withdraw(amount);
        assertEq(MockPinto(PINTO).balanceOf(address(vault)), amount);
        assertEq(silo.deposits(address(vault), 3), 0);
        assertEq(silo.deposits(address(vault), 2), s2 - s2 / 2);
        assertEq(silo.deposits(address(vault), 1), s1);
        assertEq(vault.siloPinto(), silo.held(address(vault)));
        assertEq(vault.stemAmount(2), s2 - s2 / 2);

        vault.withdraw(vault.siloPinto());
        assertEq(vault.siloPinto(), 0);
        assertEq(silo.held(address(vault)), 0);

        vm.expectRevert(VaultBase.StemShort.selector);
        vault.withdraw(1);
    }
}
