// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Chirp} from "../src/Chirp.sol";
import {ChirpBook} from "../src/ChirpBook.sol";
import {ChirpHook} from "../src/ChirpHook.sol";
import {ChirpFactory} from "../src/ChirpFactory.sol";
import {MockPinto, MockSilo, MockField, MockPeg} from "./mocks/Mocks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

/// @dev Calls the manager from inside an unlock, the way a router would. Deploy after the factory.
contract PoolProbe is IUnlockCallback {
    IPoolManager public immutable manager;

    error NotManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        uint8 kind = abi.decode(data, (uint8));
        if (kind == 1) {
            (, PoolKey memory key, IPoolManager.SwapParams memory params) =
                abi.decode(data, (uint8, PoolKey, IPoolManager.SwapParams));
            manager.swap(key, params, "");
        } else if (kind == 2) {
            (, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params) =
                abi.decode(data, (uint8, PoolKey, IPoolManager.ModifyLiquidityParams));
            manager.modifyLiquidity(key, params, "");
        } else {
            (, PoolKey memory key) = abi.decode(data, (uint8, PoolKey));
            manager.donate(key, 1, 1, "");
        }
        return "";
    }

    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params) external {
        manager.unlock(abi.encode(uint8(1), key, params));
    }

    function modify(PoolKey calldata key, int256 liquidityDelta) external {
        manager.unlock(
            abi.encode(
                uint8(2),
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: -1, tickUpper: 1, liquidityDelta: liquidityDelta, salt: 0})
            )
        );
    }

    function donate(PoolKey calldata key) external {
        manager.unlock(abi.encode(uint8(3), key));
    }
}

contract ChirpLaunchTest is Test {
    uint256 internal constant VIRTUAL = 1_000_000e6;
    uint256 internal constant BUY = 100e6;
    uint256 internal constant DEV = 1_000e6;
    address internal constant KEPT = address(0xBEEF);

    MockPinto internal pinto;
    ChirpFactory internal factory;
    Chirp internal token;
    ChirpBook internal book;
    ChirpHook internal hook;
    PoolManager internal manager;

    function test_raw_hook_without_the_flag_reverts() public {
        pinto = new MockPinto();
        MockSilo silo = new MockSilo(pinto);
        MockField field = new MockField(pinto);
        MockPeg peg = new MockPeg();
        token = new Chirp();
        book = new ChirpBook(token, address(pinto), address(silo), address(field), address(peg));
        vm.expectRevert(ChirpHook.BadHookAddress.selector);
        new ChirpHook(book, IPoolManager(address(1)));
    }

    /// @dev Audit 2026-11-17: Pinto sent to the factory's address before it exists must not kill the launch.
    function test_pregift_to_factory_address_does_not_kill_launch() public {
        pinto = new MockPinto();
        MockSilo silo = new MockSilo(pinto);
        MockField field = new MockField(pinto);
        MockPeg peg = new MockPeg();
        manager = new PoolManager(address(this));
        address factoryPredicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address bookPredicted = vm.computeCreateAddress(factoryPredicted, 2);
        (bytes32 salt,) = _mine(factoryPredicted, bookPredicted, address(manager));
        pinto.mint(address(this), DEV);
        pinto.approve(factoryPredicted, DEV);
        pinto.mint(factoryPredicted, 1);
        factory = new ChirpFactory(_launch(silo, field, peg, salt));
        assertEq(pinto.balanceOf(address(factory)), 1, "gift stays, launch lands");
        assertEq(factory.book().pintoInCurve(), DEV);
    }

    function test_create_mines_the_flag_and_ends_empty() public {
        pinto = new MockPinto();
        MockSilo silo = new MockSilo(pinto);
        MockField field = new MockField(pinto);
        MockPeg peg = new MockPeg();
        manager = new PoolManager(address(this));

        address factoryPredicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address bookPredicted = vm.computeCreateAddress(factoryPredicted, 2);
        (bytes32 salt, address hooked) = _mine(factoryPredicted, bookPredicted, address(manager));

        pinto.mint(address(this), DEV);
        pinto.approve(factoryPredicted, DEV);
        factory = new ChirpFactory(_launch(silo, field, peg, salt));
        assertEq(address(factory), factoryPredicted);

        token = factory.token();
        book = factory.book();
        hook = factory.hook();
        (bool called,) = address(factory).call(
            abi.encodeWithSignature(
                "create((address,address,address,address,address,bytes32,uint256,uint256,address))",
                address(pinto),
                address(silo),
                address(field),
                address(peg),
                address(manager),
                salt,
                VIRTUAL,
                DEV,
                KEPT
            )
        );
        assertFalse(called);

        PoolProbe probe = new PoolProbe(manager);
        _assertLaunch(bookPredicted, hooked);
        _assertHookRefuses(probe);
        _tradeThroughHook();
    }

    function _launch(MockSilo silo, MockField field, MockPeg peg, bytes32 salt)
        internal
        view
        returns (ChirpFactory.Launch memory launch)
    {
        launch = ChirpFactory.Launch({
            pinto: address(pinto),
            silo: address(silo),
            field: address(field),
            peg: address(peg),
            poolManager: address(manager),
            hookSalt: salt,
            virtualPinto: VIRTUAL,
            devBuy: DEV,
            recipient: KEPT
        });
    }

    function test_launch_needs_a_buy_paid_to_someone_else() public {
        ChirpFactory.Launch memory launch;
        launch.devBuy = 1;
        launch.recipient = address(this);
        vm.expectRevert(ChirpFactory.ZeroLaunch.selector);
        new ChirpFactory(launch);

        launch.recipient = KEPT;
        launch.devBuy = 0;
        vm.expectRevert(ChirpFactory.ZeroLaunch.selector);
        new ChirpFactory(launch);
    }

    function _mine(address predictedFactory, address bookPredicted, address poolManager)
        internal
        pure
        returns (bytes32 salt, address hooked)
    {
        bytes memory init = abi.encodePacked(type(ChirpHook).creationCode, abi.encode(bookPredicted, poolManager));
        bytes32 initHash = keccak256(init);
        for (uint256 i; i < 200_000; i++) {
            salt = bytes32(i);
            hooked = vm.computeCreate2Address(salt, initHash, predictedFactory);
            if (uint160(hooked) & 0x3FFF == 0x2AE8) return (salt, hooked);
        }
        revert("salt");
    }

    function _assertLaunch(address bookPredicted, address hooked) internal view {
        assertEq(address(book), bookPredicted);
        assertEq(address(hook), hooked);
        assertEq(uint160(address(hook)) & hook.ALL_HOOK_MASK(), hook.REQUIRED_FLAGS());
        assertEq(
            hook.REQUIRED_FLAGS(),
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(KEPT), 989_020_869_339_354_039_500_894);
        assertEq(token.balanceOf(address(book)), token.SUPPLY() - token.balanceOf(KEPT));
        assertEq(pinto.balanceOf(address(factory)), 0);
        assertEq(pinto.balanceOf(address(this)), 0);
        assertEq(book.trader(), address(hook));
        assertEq(book.factory(), address(factory));
        assertEq(book.chirpReserve(), token.balanceOf(address(book)));
        assertEq(book.pintoInCurve(), DEV);
        assertEq(book.tollStart(), block.timestamp);
        assertEq(book.buyFeeBps(), 9000);
        assertEq(book.FEE_BPS(), 100);
        assertTrue(book.opened());
        assertEq(_slot0(), hook.sqrtPriceX96());
        _resting();

        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertTrue(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertTrue(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertTrue(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    function _assertHookRefuses(PoolProbe probe) internal {
        PoolKey memory key = hook.poolKey();
        IPoolManager.ModifyLiquidityParams memory liq;
        IPoolManager.SwapParams memory swap;
        vm.expectRevert(ChirpHook.LiquidityLocked.selector);
        hook.beforeAddLiquidity(address(this), key, liq, "");
        vm.expectRevert(ChirpHook.LiquidityLocked.selector);
        hook.beforeRemoveLiquidity(address(this), key, liq, "");
        vm.expectRevert(ChirpHook.LiquidityLocked.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(ChirpHook.OnlyHookSwap.selector);
        hook.beforeSwap(address(this), key, swap, "");
        vm.expectRevert(ChirpHook.OnlyHookSwap.selector);
        hook.afterSwap(address(this), key, swap, BalanceDelta.wrap(0), "");
        vm.expectRevert(ChirpHook.OnlyFactory.selector);
        hook.launch();

        uint160 before = _slot0();
        uint160 openPrice = hook.sqrtPriceX96();
        _expectWrapped(IHooks.beforeSwap.selector, ChirpHook.OnlyHookSwap.selector);
        probe.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        _expectWrapped(IHooks.beforeAddLiquidity.selector, ChirpHook.LiquidityLocked.selector);
        probe.modify(key, 1);
        _expectWrapped(IHooks.beforeRemoveLiquidity.selector, ChirpHook.LiquidityLocked.selector);
        probe.modify(key, -1);
        _expectWrapped(IHooks.beforeDonate.selector, ChirpHook.LiquidityLocked.selector);
        probe.donate(key);
        // Outsiders cannot initialize any pool with this hook: not ours, not a lookalike.
        _expectWrapped(IHooks.beforeInitialize.selector, ChirpHook.LiquidityLocked.selector);
        manager.initialize(key, openPrice);
        PoolKey memory other = key;
        other.fee = 3000;
        other.tickSpacing = 60;
        _expectWrapped(IHooks.beforeInitialize.selector, ChirpHook.LiquidityLocked.selector);
        manager.initialize(other, openPrice);
        assertEq(_slot0(), before);
    }

    function _tradeThroughHook() internal {
        uint160 openSqrt = _slot0();
        pinto.mint(address(this), BUY);
        pinto.approve(address(hook), BUY);
        uint256 got = hook.swapExactPintoForChirp(BUY, 1, address(this));
        assertEq(got, 9_980_029_961_045_950_050_054);
        assertEq(book.pintoInCurve(), DEV + BUY);
        assertEq(book.buyFeeBps(), 9000);
        assertEq(token.balanceOf(address(book)), book.chirpReserve());
        uint160 afterBuy = _slot0();
        assertEq(afterBuy, hook.sqrtPriceX96());
        assertTrue(afterBuy != openSqrt);
        _resting();
        assertEq(pinto.allowance(address(hook), address(book)), 0);

        token.approve(address(hook), got / 2);
        uint256 paid = hook.swapExactChirpForPinto(got / 2, 1, address(this));
        assertGt(paid, 0);
        uint160 afterSell = _slot0();
        assertEq(afterSell, hook.sqrtPriceX96());
        assertTrue(afterSell != afterBuy);
        assertGe(book.pricePintoPerChirp(), book.openingPrice());
        _resting();
        assertEq(token.allowance(address(hook), address(book)), 0);

        pinto.mint(address(this), 1e6);
        pinto.approve(address(hook), 1e6);
        vm.expectRevert(ChirpHook.Slippage.selector);
        hook.swapExactPintoForChirp(1e6, type(uint256).max, address(this));
        assertEq(_slot0(), afterSell);

        uint256 left = token.balanceOf(address(this));
        uint256 curve = book.pintoInCurve();
        uint256 hits;
        for (uint256 i; i < 30; i++) {
            if (uint256(vm.load(address(book), bytes32(i))) == curve) {
                vm.store(address(book), bytes32(i), bytes32(uint256(1)));
                hits++;
            }
        }
        assertGt(hits, 0);
        token.approve(address(hook), left);
        vm.expectRevert(ChirpBook.SellTooBig.selector);
        hook.swapExactChirpForPinto(left, 1, address(this));
        assertEq(_slot0(), afterSell);
        assertEq(token.balanceOf(address(this)), left);
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, hook.poolKey().toId());
    }

    function _resting() internal view {
        assertEq(pinto.balanceOf(address(hook)), 0);
        assertEq(pinto.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(StateLibrary.getLiquidity(manager, hook.poolKey().toId()), 0);
    }

    function _expectWrapped(bytes4 hookSel, bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSel,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
