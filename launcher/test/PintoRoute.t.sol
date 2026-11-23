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
    MockSwapRouter
} from "./mocks/LauncherMocks.sol";
import {RouteHarness} from "./fork/PintoRoute.t.sol";
import {
    WETH,
    CBETH,
    PINTO,
    CBETH_WELL,
    CBETH_WELL_PUMP,
    V3_WETH_CBETH_POOL,
    SWAP_ROUTER02,
    WELL_FEE_BPS
} from "../src/Constants.sol";

/// The route on the Task 5 mocks, etched at the Constants addresses (ruling R2), so later vault tests can trust
/// the mock wiring. The real-chain proof is test/fork/PintoRoute.t.sol.
contract PintoRouteMockTest is Test {
    RouteHarness h;

    function setUp() public {
        vm.etch(WETH, address(new MockWETH()).code);
        vm.etch(CBETH, address(new MockCbEth()).code);
        vm.etch(PINTO, address(new MockPinto()).code);
        vm.etch(CBETH_WELL_PUMP, address(new MockPump()).code);
        vm.etch(CBETH_WELL, address(new MockWell()).code);
        vm.etch(V3_WETH_CBETH_POOL, address(new MockV3Pool()).code);
        vm.etch(SWAP_ROUTER02, address(new MockSwapRouter()).code);

        // 690k Pinto / 6.5 cbETH, spot = EMA; tick 1345 ≈ 1.144 WETH per cbETH, router spot = TWAP.
        MockWell(CBETH_WELL).setReserves(690_000e6, 6.5 ether);
        MockPump(CBETH_WELL_PUMP).setReserves(CBETH_WELL, 690_000e6, 6.5 ether);
        MockPinto(PINTO).mint(CBETH_WELL, 690_000e6);
        MockCbEth(CBETH).mint(CBETH_WELL, 6.5 ether);
        MockV3Pool(V3_WETH_CBETH_POOL).setTick(1345);

        h = new RouteHarness();
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, h.cbEthForWeth(1 ether));
        MockSwapRouter(SWAP_ROUTER02).setRate(CBETH, WETH, h.wethForCbEth(1 ether));
        MockCbEth(CBETH).mint(SWAP_ROUTER02, 100 ether);
        MockWETH(WETH).mint(SWAP_ROUTER02, 100 ether);
    }

    function test_route_on_mocks() public {
        MockWETH(WETH).mint(address(h), 0.05 ether);
        uint256 pinto = h.wethToPinto(0.05 ether);
        // Fee-less mock well pays the guard quote grossed back up by the 25 bps the guard deducts.
        assertApproxEqRel(pinto, h.pintoForCbEth(h.cbEthForWeth(0.05 ether)) * 1e4 / (1e4 - WELL_FEE_BPS), 1e15);
        assertEq(MockPinto(PINTO).balanceOf(address(h)), pinto);

        uint256 weth = h.pintoToWeth(pinto);
        assertApproxEqRel(weth, 0.05 ether, 1e15);
        assertEq(MockPinto(PINTO).balanceOf(address(h)), 0);
        assertEq(MockCbEth(CBETH).balanceOf(address(h)), 0);
    }

    /// Review Focus 5 on mocks: well spot 5% off the pump EMA → the Pinto leg reverts.
    function test_mock_spot_moved_reverts() public {
        MockWell(CBETH_WELL).setReserves(655_500e6, 6.5 ether);
        MockWETH(WETH).mint(address(h), 0.05 ether);
        vm.expectPartialRevert(MockWell.SlippageOut.selector);
        h.wethToPinto(0.05 ether);
    }

    /// Router spot 5% off the TWAP → the v3 leg reverts.
    function test_mock_v3_spot_moved_reverts() public {
        MockSwapRouter(SWAP_ROUTER02).setRate(WETH, CBETH, h.cbEthForWeth(1 ether) * 95 / 100);
        MockWETH(WETH).mint(address(h), 0.05 ether);
        vm.expectRevert(bytes("Too little received"));
        h.wethToPinto(0.05 ether);
    }
}
