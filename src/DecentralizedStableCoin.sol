//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "../lib/forge-std/src/console.sol";

/**
 * @title DecentralizedStableCoin
 * @author Lotus
 * Collateral: External (wETH & wBTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged / Anchored to USD
 *
 * This is the contract meant to by governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero(); // 必须大于零
    error DecentralizedStableCoin__BurnAmountExceedsBalance(); // 燃烧金额必须大于零
    error DecentralizedStableCoin__NotZeroAddress(); // 不能为零地址

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    // 销毁
    function burn(uint256 _amount) public override onlyOwner {
        // uint256 balance = msg.sender.balance; // 用于获取调用者的以太币（Ether）余额，单位是wei
        uint256 balance = balanceOf(msg.sender); // 用于获取调用者的代币余额，适用于代币相关的操作，如转移、销毁等
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (_amount > balance) {
            console.log(balance);
            console.log(_amount);
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    // 铸造
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
