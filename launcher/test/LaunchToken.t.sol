// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SUPPLY} from "../src/Constants.sol";

contract LaunchTokenTest is Test {
    LaunchToken t;
    address mintTo = address(0xF00D);

    function setUp() public {
        t = new LaunchToken("Name", "SYM", "ipfs://img", "https://surcofi.com/api/launcher/meta/test.json", mintTo);
    }

    function test_supply_minted_once() public view {
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(mintTo), SUPPLY);
        assertEq(t.imageURI(), "ipfs://img");
        assertEq(t.imageUrl(), "ipfs://img");
        assertEq(t.metadataURI(), "https://surcofi.com/api/launcher/meta/test.json");
        assertEq(t.metadataUri(), "https://surcofi.com/api/launcher/meta/test.json");
        assertEq(t.contractURI(), "https://surcofi.com/api/launcher/meta/test.json");
        assertEq(t.decimals(), 18);
    }

    function test_burn_reduces_supply() public {
        vm.prank(mintTo);
        t.burn(5 ether);
        assertEq(t.totalSupply(), SUPPLY - 5 ether);
        assertEq(t.balanceOf(mintTo), SUPPLY - 5 ether);
    }

    function test_burn_over_balance_reverts() public {
        vm.expectRevert(LaunchToken.Balance.selector);
        t.burn(1);
    }

    function testFuzz_transfer_has_no_fee(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        address to = address(0xBEEF);
        vm.prank(mintTo);
        t.transfer(to, amount);
        assertEq(t.balanceOf(to), amount);
        assertEq(t.balanceOf(mintTo), SUPPLY - amount);
    }

    function test_no_mint_selector() public {
        (bool ok,) = address(t).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
    }
}
