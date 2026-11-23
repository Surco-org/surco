// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SUPPLY} from "./Constants.sol";

/// @notice Fixed-supply ERC-20. Minted once in the constructor; supply only ever falls, by a holder burning their own coins.
contract LaunchToken {
    string public name;
    string public symbol;
    string public imageURI;
    string public metadataURI;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error ZeroAddress();
    error Balance();
    error Allowance();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory imageURI_,
        string memory metadataURI_,
        address mintTo
    ) {
        if (mintTo == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        imageURI = imageURI_;
        metadataURI = metadataURI_;
        totalSupply = SUPPLY;
        balanceOf[mintTo] = SUPPLY;
        emit Transfer(address(0), mintTo, SUPPLY);
    }

    /// @notice Alias for Base/launchpad indexers expecting camelCase `metadataUri()` (e.g. Base listings).
    function metadataUri() external view returns (string memory) {
        return metadataURI;
    }

    /// @notice ERC-7572 contract-level metadata URI alias.
    function contractURI() external view returns (string memory) {
        return metadataURI;
    }

    /// @notice Alias for indexers expecting `imageUrl()`.
    function imageUrl() external view returns (string memory) {
        return imageURI;
    }

    function burn(uint256 amount) external {
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert Balance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert Allowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert Balance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
