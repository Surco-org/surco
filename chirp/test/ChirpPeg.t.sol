// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChirpPeg} from "../src/ChirpPeg.sol";

contract DeltaBStub {
    int256 public deltaB;

    function set(int256 next) external {
        deltaB = next;
    }

    function totalDeltaB() external view returns (int256) {
        return deltaB;
    }
}

contract ChirpPegTest is Test {
    function test_negative_delta_is_under_a_dollar() public {
        DeltaBStub stub = new DeltaBStub();
        ChirpPeg peg = new ChirpPeg(address(stub));
        assertEq(address(peg.pinto()), address(stub));
        assertFalse(peg.belowPeg());

        stub.set(-1);
        assertTrue(peg.belowPeg());

        stub.set(-640_000e6);
        assertTrue(peg.belowPeg());

        stub.set(1);
        assertFalse(peg.belowPeg());
    }

    function test_zero_diamond_reverts_and_there_is_no_owner() public {
        vm.expectRevert(ChirpPeg.ZeroAddress.selector);
        new ChirpPeg(address(0));

        ChirpPeg peg = new ChirpPeg(address(1));
        (bool owner,) = address(peg).call(abi.encodeWithSignature("owner()"));
        (bool set,) = address(peg).call(abi.encodeWithSignature("setPinto(address)", address(2)));
        assertFalse(owner);
        assertFalse(set);
        assertEq(address(peg.pinto()), address(1));
    }
}
