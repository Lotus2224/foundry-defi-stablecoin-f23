//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    // uint8 _decimals, int256 _initialAnswer
    uint8 private constant DECIMAL = 8;
    int256 private constant ETH_USD_PRICE = 2000e8; // 2,000 USD
    int256 private constant BTC_USD_PRICE = 100000e8; // 100,000 USD

    // address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress
    struct NetWorkConfig {
        address wETHAddress;
        address wBTCAddress;
        address wETHUsdPriceFeed;
        address wBTCUsdPriceFeed;
        uint256 deployerKey;
    }

    NetWorkConfig public activeNetworkConfig; // 活动网络配置

    constructor() {
        if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetWorkConfig memory) {
        return NetWorkConfig({
            wETHAddress: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wBTCAddress: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            wETHUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wBTCUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetWorkConfig memory) {
        if (activeNetworkConfig.wETHUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        // Mock ETH
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMAL, ETH_USD_PRICE);
        ERC20Mock wETHMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8);
        // Mock BTC
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMAL, BTC_USD_PRICE);
        ERC20Mock wBTCMock = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8);
        vm.stopBroadcast();

        return NetWorkConfig({
            wETHAddress: address(wETHMock),
            wBTCAddress: address(wBTCMock),
            wETHUsdPriceFeed: address(ethUsdPriceFeed),
            wBTCUsdPriceFeed: address(btcUsdPriceFeed),
            deployerKey: vm.envUint("DEFAULT_ANVIL_PRIVATE_KEY")
        });
    }
}