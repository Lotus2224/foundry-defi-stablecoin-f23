//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin dsc, DSCEngine engine, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        (address wETHAddress, address wBTCAddress, address wETHUsdPriceFeed, address wBTCUsdPriceFeed,) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [wETHAddress, wBTCAddress];
        priceFeedAddresses = [wETHUsdPriceFeed, wBTCUsdPriceFeed];

        vm.startBroadcast();
        dsc = new DecentralizedStableCoin();
        // address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress
        engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        dsc.transferOwnership(address(engine)); // Transfer ownership to DSCEngine
        vm.stopBroadcast();
    }
}