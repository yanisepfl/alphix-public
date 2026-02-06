// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title MockUSDT
 * @author Alphix
 * @notice Mock for USDT that has non-standard behavior (in contrast to ERC-20).
 * @dev Transfer and approval functions do not return boolean values.
 *      Approval requires setting to 0 before changing to non-zero value.
 */
contract MockUSDT {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    /* USDT NON-STANDARD FUNCTIONS */

    /**
     * @dev Does not return boolean. Non-standard USDT behavior.
     */
    function transfer(address to, uint256 amount) public virtual {
        address owner_ = msg.sender;
        _transfer(owner_, to, amount);
    }

    /**
     * @dev Does not return boolean. Non-standard USDT behavior.
     *      Requires approval to be 0 before setting to non-zero.
     */
    function approve(address spender, uint256 amount) public virtual {
        address owner_ = msg.sender;
        require(!((amount != 0) && (_allowances[owner_][spender] != 0)), "Reset allowance first");
        _approve(owner_, spender, amount);
    }

    /**
     * @dev Does not return boolean. Non-standard USDT behavior.
     */
    function transferFrom(address from, address to, uint256 amount) public virtual {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
    }

    /* MOCK FUNCTIONS */

    /**
     * @notice Mints tokens to an address.
     * @param to The recipient address.
     * @param value The amount to mint.
     */
    function mint(address to, uint256 value) public {
        _mint(to, value);
    }

    /**
     * @notice Burns tokens from an address.
     * @param from The address to burn from.
     * @param value The amount to burn.
     */
    function burn(address from, uint256 value) public {
        _burn(from, value);
    }

    /* ERC-20 STANDARD VIEW FUNCTIONS */

    function name() public view virtual returns (string memory) {
        return "Mock USDT";
    }

    function symbol() public view virtual returns (string memory) {
        return "mUSDT";
    }

    function decimals() public view virtual returns (uint8) {
        return 6;
    }

    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) public view virtual returns (uint256) {
        return _allowances[owner_][spender];
    }

    /* INTERNAL FUNCTIONS */

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }

        emit IERC20.Transfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit IERC20.Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= amount;
        }

        emit IERC20.Transfer(account, address(0), amount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal virtual {
        require(owner_ != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner_][spender] = amount;
        emit IERC20.Approval(owner_, spender, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner_, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner_, spender, currentAllowance - amount);
            }
        }
    }
}
