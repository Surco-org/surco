// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Basin MultiFlowPump (0xBA51AAaA66DaB6c236B356ad713f759c206DcB93, Sourcify-verified).
interface IPump {
    function readInstantaneousReserves(address well, bytes memory data) external view returns (uint256[] memory);
}
