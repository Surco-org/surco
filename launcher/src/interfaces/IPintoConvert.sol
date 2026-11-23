// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pinto's ConvertFacet (Diamond facet 0x978EC1C303999e0a4EB4928dc3a4b39F0e9B7Fa0 on Base, Sourcify-verified),
///         Lambda -> Lambda only. Findings below were read from that source and proven on a Base fork at block
///         60,050,000 (test/fork/LambdaMerge.t.sol).
///
///         Encoding: convertData = abi.encode(uint8 kind, uint256 amount, address token), kind LAMBDA_LAMBDA = 0
///         (LibConvertData.ConvertKind: LAMBDA_LAMBDA, BEANS_TO_WELL_LP, WELL_LP_TO_BEANS, ANTI_LAMBDA_LAMBDA).
///         `amount` is the total taken from `stems` in order (`amounts[i]` each, the last one trimmed to fit) and
///         must be removed in full, else "Convert: Not enough tokens removed.".
///
///         Germination: a stem >= getGerminatingStem(token) is skipped, not refused, so it does not count toward
///         `amount`. Pass the non-germinating total and the germinating deposits stay as they were. A deposit
///         germinates in the season it is made and the next one.
///
///         Stem rule: grownStalk = sum((stemTip - stem_i) * bdv_i), bdv = sum(bdv_i) (= amount for Pinto);
///         toStem = stemTip - grownStalk / bdv (rounded down, so toStem is never above the youngest input and the
///         merged deposit is never germinating). The account is minted bdv * stalkIssuedPerBdv + grownStalk exactly,
///         so its Stalk does not fall (measured: equal to the wei). No penalty: the stalk penalty and convert
///         capacity only apply to Pinto <-> LP converts. Proven below peg; the source reads no deltaB for a
///         same-token convert, so peg does not matter. Gas on the fork: ~370k for 3 stems with warm storage,
///         ~610k cold; ~380k for 10 stems warm.
interface IPintoConvert {
    function convert(bytes calldata convertData, int96[] calldata stems, uint256[] calldata amounts)
        external
        payable
        returns (int96 toStem, uint256 fromAmount, uint256 toAmount, uint256 fromBdv, uint256 toBdv);
}
