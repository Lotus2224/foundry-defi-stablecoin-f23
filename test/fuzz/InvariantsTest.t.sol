//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

// Have our invariant aka properties
// What are our invariants?
// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address wETHAddress;
    address wBTCAddress;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wETHAddress, wBTCAddress,,,) = config.activeNetworkConfig();
        // targetContract(address(engine));
        // hey, don't call redeem collateral, unless there is collateral to redeem
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply(); // DSC的总供应量
        uint256 totalWethDeposited = IERC20(wETHAddress).balanceOf(address(engine)); // 总存入的Weth
        uint256 totalBtcDeposited = IERC20(wBTCAddress).balanceOf(address(engine)); // 总存入的Wbtc

        uint256 wethValue = engine.getUsdValue(wETHAddress, totalWethDeposited); // 总weth的实际价值
        uint256 wbtcValue = engine.getUsdValue(wBTCAddress, totalBtcDeposited); // 总wbtc的实际价值

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply: ", totalSupply);
        console.log("timeMintIsCalled: ", handler.timeMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    // function invariant_gettersShouldNotRevert() public view {
    //     engine.getLiquidationBonus();
    //     engine.getPrecision();
    // }
}
