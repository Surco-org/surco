// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed 1 billion Chirp. Minted once to the factory. Only the book can burn, and only its own balance.
contract Chirp {
    string public constant name = "Chirp";
    string public constant symbol = "CHIRP";
    uint8 public constant decimals = 18;
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    uint256 public totalSupply;
    address public immutable factory;
    address public book;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error OnlyFactory();
    error OnlyBook();
    error BookSet();
    error ZeroAddress();
    error Balance();
    error Allowance();

    constructor() {
        factory = msg.sender;
        totalSupply = SUPPLY;
        balanceOf[msg.sender] = SUPPLY;
        emit Transfer(address(0), msg.sender, SUPPLY);
    }

    function setBook(address next) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (book != address(0)) revert BookSet();
        if (next == address(0)) revert ZeroAddress();
        book = next;
    }

    function burn(uint256 amount) external {
        if (msg.sender != book) revert OnlyBook();
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
