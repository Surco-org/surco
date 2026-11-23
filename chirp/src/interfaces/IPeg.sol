// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice True when Pinto is below its $1 peg. The address is chosen at launch.
///         This contract does not guess a deltaB selector.
interface IPeg {
    function belowPeg() external view returns (bool);
}
