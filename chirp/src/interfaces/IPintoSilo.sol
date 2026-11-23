// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Live Pinto silo surface. Amounts are raw 6-decimal Pinto. Mode 0 is EXTERNAL.
///         withdrawDeposit pays the token in the same transaction, including germinating stems.
interface IPintoSilo {
    function deposit(address token, uint256 amount, uint8 mode)
        external
        returns (uint256 amountDeposited, uint256 bdv, int96 stem);

    function withdrawDeposit(address token, int96 stem, uint256 amount, uint8 mode) external;

    function plant() external returns (uint256 beans, int96 stem);

    function getGerminatingStem(address token) external view returns (int96);

    function stemTipForToken(address token) external view returns (int96);

    function getDeposit(address account, address token, int96 stem)
        external
        view
        returns (uint256 amount, uint256 bdv);
}
