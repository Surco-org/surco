// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Basin Well. The cbETH well is an ERC1967 proxy over a clone of Basin's WellUpgradeable; these signatures are
/// checked against the Sourcify-verified implementation 0xBA510990a720725aB1F9a0D231F045fc906909f4 (2026-11-20).
interface IWell {
    struct Call {
        address target;
        bytes data;
    }

    function pumps() external view returns (Call[] memory);
    function getReserves() external view returns (uint256[] memory);
    function getSwapOut(address fromToken, address toToken, uint256 amountIn) external view returns (uint256);
    function swapFrom(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
