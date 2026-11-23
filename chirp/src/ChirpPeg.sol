// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPeg} from "./interfaces/IPeg.sol";

/// @notice Pinto's SeasonGettersFacet.totalDeltaB. It sums every whitelisted well, then caps the size.
///         The cap keeps the sign. Negative means Pinto is under $1.
interface IPintoDeltaB {
    function totalDeltaB() external view returns (int256);
}

/// @notice Ownerless peg read. The launch picks the address. On Base that is the Pinto diamond
///         0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f. Temperature is not read here.
contract ChirpPeg is IPeg {
    IPintoDeltaB public immutable pinto;

    error ZeroAddress();

    constructor(address pinto_) {
        if (pinto_ == address(0)) revert ZeroAddress();
        pinto = IPintoDeltaB(pinto_);
    }

    function belowPeg() external view returns (bool) {
        return pinto.totalDeltaB() < 0;
    }
}
