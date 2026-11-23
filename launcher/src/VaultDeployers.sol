// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {LauncherHook} from "./LauncherHook.sol";
import {RedeemVault} from "./RedeemVault.sol";
import {BurnVault} from "./BurnVault.sol";

// The two vaults' initcode (~12.8 kB + ~15.2 kB) does not fit in the factory's 24,576-byte runtime, nor together in
// one deployer, so each mode gets its own. LauncherFactory creates both in its constructor and is their only caller.
// A vault's `factory` (VaultBase) is therefore its deployer, which is why BurnDeployer relays `setPoolKey`.

contract RedeemDeployer {
    address public immutable launcher = msg.sender;

    error OnlyLauncher();

    function deploy(LaunchToken coin, address safe, address creatorPayout, uint16 creatorBps)
        external
        returns (RedeemVault)
    {
        if (msg.sender != launcher) revert OnlyLauncher();
        return new RedeemVault(coin, safe, creatorPayout, creatorBps);
    }
}

contract BurnDeployer {
    address public immutable launcher = msg.sender;

    error OnlyLauncher();

    modifier onlyLauncher() {
        if (msg.sender != launcher) revert OnlyLauncher();
        _;
    }

    function deploy(
        LaunchToken coin,
        address safe,
        address creatorPayout,
        uint16 creatorBps,
        IPoolManager manager,
        LauncherHook hook
    ) external onlyLauncher returns (BurnVault) {
        return new BurnVault(coin, safe, creatorPayout, creatorBps, manager, hook);
    }

    function setPoolKey(BurnVault vault, PoolKey calldata key) external onlyLauncher {
        vault.setPoolKey(key);
    }
}
