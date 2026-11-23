// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Chirp} from "../src/Chirp.sol";
import {ChirpBook} from "../src/ChirpBook.sol";
import {ChirpFactory} from "../src/ChirpFactory.sol";
import {ChirpHook} from "../src/ChirpHook.sol";
import {ChirpPeg} from "../src/ChirpPeg.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @notice Launch script. Nonce 0 deploys ChirpPeg, nonce 1 approves Pinto to the
///         factory that will exist at nonce 2, nonce 2 deploys ChirpFactory.
///         Set DEPLOYER and HOOK_SALT / HOOK_EXPECTED env vars to simulate or deploy.
contract DeployChirp is Script {
    address internal constant RECIPIENT = 0x0dB14dc82CBB0ce820F65c9796E0bC9E19eF08bf;
    address internal constant PINTO = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
    address internal constant DIAMOND = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant VIRTUAL = 10_000_000e6;
    uint256 internal constant DEV_BUY = 1_000e6;
    uint256 internal constant KEPT = 98_990_199_970_202_949_907_959;
    uint256 internal constant MIN_ETH = 150_000_000_000_000;
    bytes32 internal constant HOOK_SALT = 0x9bf49a6a0755f953811fce125f2683d50429c3bb49e0741429858aa52eae155f;
    address internal constant HOOK_EXPECTED = 0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        require(block.chainid == 8453, "chain");
        require(vm.getNonce(deployer) == 0, "nonce");
        require(deployer.code.length == 0, "eoa");
        // At least: a stranger can send dust to this wallet. Exactly DEV_BUY must leave it.
        uint256 pintoBefore = IERC20(PINTO).balanceOf(deployer);
        require(pintoBefore >= DEV_BUY, "pinto");
        require(deployer.balance >= MIN_ETH, "eth");

        address pegPredicted = vm.computeCreateAddress(deployer, 0);
        address factoryPredicted = vm.computeCreateAddress(deployer, 2);
        address tokenPredicted = vm.computeCreateAddress(factoryPredicted, 1);
        address bookPredicted = vm.computeCreateAddress(factoryPredicted, 2);
        address hookPredicted = _hook(factoryPredicted, bookPredicted);
        require(hookPredicted == HOOK_EXPECTED, "salt");
        bytes32 salt = HOOK_SALT;

        console2.log("peg", pegPredicted);
        console2.log("factory", factoryPredicted);
        console2.log("token", tokenPredicted);
        console2.log("book", bookPredicted);
        console2.log("hook", hookPredicted);
        console2.logBytes32(salt);

        uint256 factoryPintoBefore = IERC20(PINTO).balanceOf(factoryPredicted);
        vm.startBroadcast(deployer);
        ChirpPeg peg = new ChirpPeg(DIAMOND);
        require(address(peg) == pegPredicted, "peg addr");
        require(IERC20(PINTO).approve(factoryPredicted, DEV_BUY), "approve");
        ChirpFactory factory = new ChirpFactory(
            ChirpFactory.Launch({
                pinto: PINTO,
                silo: DIAMOND,
                field: DIAMOND,
                peg: pegPredicted,
                poolManager: POOL_MANAGER,
                hookSalt: salt,
                virtualPinto: VIRTUAL,
                devBuy: DEV_BUY,
                recipient: RECIPIENT
            })
        );
        vm.stopBroadcast();

        require(address(factory) == factoryPredicted, "factory addr");
        Chirp token = factory.token();
        ChirpBook book = factory.book();
        ChirpHook hook = factory.hook();
        require(address(token) == tokenPredicted, "token addr");
        require(address(book) == bookPredicted, "book addr");
        require(address(hook) == hookPredicted, "hook addr");
        require(address(peg.pinto()) == DIAMOND, "peg");
        require(address(book.peg()) == pegPredicted, "book peg");
        require(address(book.silo()) == DIAMOND, "silo");
        require(address(book.field()) == DIAMOND, "field");
        require(book.pinto() == PINTO, "pinto");
        require(book.factory() == factoryPredicted, "book factory");
        require(book.trader() == hookPredicted, "trader");
        require(book.REFERRER() == RECIPIENT, "referrer");
        require(book.opened(), "open");
        require(book.virtualPinto() == VIRTUAL, "cap");
        require(book.pintoInCurve() == DEV_BUY, "curve");
        require(book.openingPrice() == 10_000, "open price");
        require(book.tollStart() == block.timestamp, "clock");
        require(book.buyFeeBps() == 9000, "toll");
        require(token.totalSupply() == token.SUPPLY(), "supply");
        require(token.balanceOf(RECIPIENT) == KEPT, "kept");
        require(token.balanceOf(address(book)) == book.chirpReserve(), "shelf");
        require(token.balanceOf(factoryPredicted) == 0, "factory chirp");
        require(token.balanceOf(deployer) == 0, "deployer chirp");
        require(IERC20(PINTO).balanceOf(factoryPredicted) == factoryPintoBefore, "factory pinto");
        require(IERC20(PINTO).balanceOf(deployer) == pintoBefore - DEV_BUY, "deployer pinto");
        require(IERC20(PINTO).balanceOf(hookPredicted) == 0, "hook pinto");
        require(token.balanceOf(hookPredicted) == 0, "hook chirp");
        require(uint160(hookPredicted) & hook.ALL_HOOK_MASK() == hook.REQUIRED_FLAGS(), "flags");
        require(book.pricePintoPerChirp() > book.openingPrice(), "price");
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(IPoolManager(POOL_MANAGER), hook.poolKey().toId());
        require(sqrtPrice == hook.sqrtPriceX96(), "sticker");
        require(StateLibrary.getLiquidity(IPoolManager(POOL_MANAGER), hook.poolKey().toId()) == 0, "liq");
        console2.log("kept", token.balanceOf(RECIPIENT));
        console2.log("price", book.pricePintoPerChirp());
        console2.log("ok", block.number);
    }

    function _hook(address predictedFactory, address bookPredicted) internal pure returns (address hooked) {
        bytes memory init = abi.encodePacked(type(ChirpHook).creationCode, abi.encode(bookPredicted, POOL_MANAGER));
        hooked = vm.computeCreate2Address(HOOK_SALT, keccak256(init), predictedFactory);
        require(uint160(hooked) & 0x3FFF == 0x2AE8, "flags");
    }
}
