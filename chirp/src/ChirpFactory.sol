// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Chirp} from "./Chirp.sol";
import {ChirpBook} from "./ChirpBook.sol";
import {ChirpHook} from "./ChirpHook.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Deploys the token, the book, and the hook, opens the curve, and initializes the pool.
///         The deployer then buys once, at 1%, and the coins are paid to a wallet he keeps.
///         The toll clock starts after that buy, in the same transaction. This contract keeps nothing.
///         Peg and the opening cap are fixed by that deployment. There is no later create a stranger
///         can front-run. The hook salt is mined off-chain. This contract does not loop.
contract ChirpFactory {
    struct Launch {
        address pinto;
        address silo;
        address field;
        address peg;
        address poolManager;
        bytes32 hookSalt;
        uint256 virtualPinto;
        uint256 devBuy;
        address recipient;
    }

    Chirp public immutable token;
    ChirpBook public immutable book;
    ChirpHook public immutable hook;

    error Dust();
    error ZeroLaunch();
    error PullFailed();

    constructor(Launch memory launch) {
        if (launch.devBuy == 0 || launch.recipient == address(0) || launch.recipient == msg.sender) {
            revert ZeroLaunch();
        }
        // Nonce order is load-bearing for the salt: token, then book, then CREATE2 hook.
        token = new Chirp();
        book = new ChirpBook(token, launch.pinto, launch.silo, launch.field, launch.peg);
        hook = new ChirpHook{salt: launch.hookSalt}(book, IPoolManager(launch.poolManager));
        if (
            launch.recipient == address(hook) || launch.recipient == address(book) || launch.recipient == address(token)
                || launch.recipient == address(this)
        ) revert ZeroLaunch();

        book.setTrader(address(hook));
        token.setBook(address(book));
        if (!token.transfer(address(book), token.SUPPLY())) revert Dust();
        book.open(launch.virtualPinto);
        // No external call sits between the hook's create and this initialize.
        hook.launch();

        // The clock is still off, so this buy pays 1%. The coins do not stay on the deployer.
        IERC20 paid = IERC20(launch.pinto);
        // Anyone can send Pinto to this address before it exists. Check the change, not zero.
        uint256 pintoBefore = paid.balanceOf(address(this));
        if (!paid.transferFrom(msg.sender, address(this), launch.devBuy)) revert PullFailed();
        if (!paid.approve(address(hook), launch.devBuy)) revert PullFailed();
        hook.swapExactPintoForChirp(launch.devBuy, 1, launch.recipient);
        book.startClock();

        if (token.balanceOf(address(this)) != 0) revert Dust();
        if (paid.balanceOf(address(this)) != pintoBefore) revert Dust();
    }
}
