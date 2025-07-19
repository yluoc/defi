//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wEthUsdPriceFeed;
        address wBtcUsdPriceFeed;
        address wEth;
        address wBtc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    uint256 public DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetWorkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetWorkConfig = getSepoliaEthConfig();
        } else {
            activeNetWorkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wEthUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wBtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            wEth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wBtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetWorkConfig.wEthUsdPriceFeed != address(0)) {
            return activeNetWorkConfig;
        }

        vm.startBroadcast();

        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        ERC20Mock wEthMock = new ERC20Mock();
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wBtcMock = new ERC20Mock();

        vm.stopBroadcast();

        return NetworkConfig({
            wEthUsdPriceFeed: address(ethUsdPriceFeed),
            wBtcUsdPriceFeed: address(btcUsdPriceFeed),
            wEth: address(wEthMock),
            wBtc: address(wBtcMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
