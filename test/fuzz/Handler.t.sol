//SPDX-License-Identifier: MIT
// Handler is going to narrow down the way we call function

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    uint256 public timeMintIsCalled;
    address[] public usersWithCollateralDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // The max uint96 value

    using OracleLib for AggregatorV3Interface;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // 存入抵押品
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // double push
        usersWithCollateralDeposited.push(msg.sender);
    }

    // 赎回抵押品
    // function redeemCollateral2(uint256 collateralSeed, uint256 amountCollateral) public {
    //     ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    //     uint256 maxRedeemCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
    //     amountCollateral = bound(amountCollateral, 0, maxRedeemCollateral);
    //     vm.assume(amountCollateral != 0); // 假设amountCollateral != 0, 测试中的用例需要满足此条件
    //     vm.assume(engine.getHealthFactor(msg.sender) > 1e18); // 新增: 只有 Health Factor > 1e18 才能赎回

    //     vm.prank(msg.sender);
    //     engine.redeemCollateral(address(collateral), amountCollateral);
    // }

    // 赎回抵押品
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxRedeemCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxRedeemCollateral);
        vm.assume(amountCollateral != 0);
        uint256 healthFactorBeforeRedeem = engine.getHealthFactor(msg.sender);
        vm.assume(healthFactorBeforeRedeem > 1e18); //  Health Factor 大于 1

        uint256 maxRedeemBasedOnHealthFactor =
            calculateMaxRedeemBasedOnHealthFactor(msg.sender, address(collateral), healthFactorBeforeRedeem);
        amountCollateral = bound(amountCollateral, 0, maxRedeemBasedOnHealthFactor);
        vm.assume(amountCollateral != 0);

        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    // 铸造DSC
    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        vm.assume(usersWithCollateralDeposited.length != 0);
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);
        vm.assume(maxDscToMint > 0);
        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        vm.assume(amountDscToMint != 0);

        vm.startPrank(sender);
        engine.mintDsc(amountDscToMint);
        vm.stopPrank();

        timeMintIsCalled++;
    }

    // 更新抵押品价格
    // This breaks our invariant test suite!!!!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // 从种子中获取抵押品
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function calculateMaxRedeemBasedOnHealthFactor(address user, address collateralToken, uint256 healthFactorBefore)
        public
        view
        returns (uint256)
    {
        // 1. 获取用户账户信息
        (uint256 totalDscMinted, uint256 collateralValueInUsdBefore) = engine.getAccountInformation(user);
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(user, collateralToken);
        if (collateralBalance == 0) {
            return 0;
        }
        AggregatorV3Interface priceFeed = AggregatorV3Interface(engine.getCollateralTokenPriceFeed(collateralToken));
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        uint256 collateralPrice = uint256(price) * engine.getAdditionalFeedPrecision();

        //目标健康因子
        uint256 targetHealthFactor = healthFactorBefore;

        // 最大赎回量
        uint256 maxRedeem = 0;

        // 使用二分查找逼近最大赎回量
        uint256 low = 0;
        uint256 high = collateralBalance;
        while (low <= high) {
            uint256 mid = (low + high) / 2;

            // 3. 计算赎回 mid 数量抵押品后的健康因子
            uint256 newCollateralValueInUsd =
                collateralValueInUsdBefore - (collateralPrice * mid) / engine.getPrecision();
            uint256 newHealthFactor = engine.calculateHealthFactor(totalDscMinted, newCollateralValueInUsd);

            // 4. 判断健康因子是否满足要求
            if (newHealthFactor >= targetHealthFactor) {
                // 如果满足要求，则尝试更大的赎回量
                maxRedeem = mid;
                low = mid + 1;
            } else {
                // 如果不满足要求，则尝试更小的赎回量
                high = mid - 1;
            }
        }

        return maxRedeem;
    }
}
