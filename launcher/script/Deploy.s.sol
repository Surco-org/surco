// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "chirp/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LauncherHook} from "../src/LauncherHook.sol";
import {LauncherFactory} from "../src/LauncherFactory.sol";
import {VeChirp} from "../src/VeChirp.sol";
import {CollectiveSilo} from "../src/CollectiveSilo.sol";
import {CHIRP, POOL_MANAGER, WETH} from "../src/Constants.sol";

/// @notice Deploys the shared hook, VeChirp ERC-721 gauge, CollectiveSilo, and LauncherFactory in one back-to-back
///         nonce sequence with zero circular dependencies and zero admin setters:
///         nonce + 0 = LauncherHook (CREATE2 mined for factory at nonce + 3)
///         nonce + 1 = VeChirp(CHIRP, hook, baseURI)
///         nonce + 2 = CollectiveSilo(POOL_MANAGER, hook, veChirp)
///         nonce + 3 = LauncherFactory(POOL_MANAGER, hook, safe, collectiveSilo)
///         SIMULATE ONLY until explicit go:
///         LAUNCHER_SAFE=0x… forge script script/Deploy.s.sol --fork-url "$BASE_RPC_URL"
contract Deploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant FLAG_MASK = 0x3FFF;
    uint160 internal constant FLAGS = 0x2AEC;
    string internal constant VE_BASE_URI = "https://surcofi.com/api/launcher/ve/";

    function run() external returns (LauncherHook, LauncherFactory, VeChirp, CollectiveSilo) {
        return deploy(vm.envOr("LAUNCHER_SAFE", address(0)));
    }

    function deploy(address safe)
        public
        returns (LauncherHook hook, LauncherFactory factory, VeChirp veChirp, CollectiveSilo collectiveSilo)
    {
        require(safe != address(0), "LAUNCHER_SAFE unset or zero");
        require(block.chainid == 8453, "Base mainnet only");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        uint64 nonce = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, nonce + 3);
        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), predicted, WETH);
        (bytes32 salt, address mined) = mineSalt(keccak256(abi.encodePacked(type(LauncherHook).creationCode, args)));

        hook = new LauncherHook{salt: salt}(IPoolManager(POOL_MANAGER), predicted, WETH);
        veChirp = new VeChirp(IERC20(CHIRP), hook, VE_BASE_URI);
        collectiveSilo = new CollectiveSilo(IPoolManager(POOL_MANAGER), hook, veChirp);
        factory = new LauncherFactory(IPoolManager(POOL_MANAGER), hook, safe, address(collectiveSilo));
        vm.stopBroadcast();

        require(address(hook) == mined, "hook address");
        require(address(factory) == predicted, "factory address");
        require(hook.factory() == address(factory), "hook.factory");
        require(factory.collectiveSilo() == address(collectiveSilo), "factory.collectiveSilo");

        console.log("deployer", deployer, "nonce", nonce);
        console.log("hook", address(hook));
        console.log("hook salt");
        console.logBytes32(salt);
        console.log("veChirp", address(veChirp));
        console.log("collectiveSilo", address(collectiveSilo));
        console.log("factory", address(factory));
        console.log("redeemDeployer", address(factory.redeemDeployer()));
        console.log("burnDeployer", address(factory.burnDeployer()));
        console.log("safe", safe);
    }

    function mineSalt(bytes32 initCodeHash) public view returns (bytes32 salt, address hook) {
        for (uint256 i;; i++) {
            salt = bytes32(i);
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash));
            hook = address(uint160(uint256(h)));
            if (uint160(hook) & FLAG_MASK == FLAGS && hook.code.length == 0) {
                return (salt, hook);
            }
        }
    }
}
