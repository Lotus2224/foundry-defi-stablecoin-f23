//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address wETHAddress;
    address wBTCAddress;
    address wETHUsdPriceFeed;
    address wBTCUsdPriceFeed;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; // amount collateral 抵押品数量
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether; // 初始的ERC20余额
    uint256 public constant MIN_HEALTH_FACTOR = 1e18; // 最小的健康因子
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // 清算阈值
    uint256 public amountToMint = 100 ether; // amount to mint 铸造数量

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wETHAddress, wBTCAddress, wETHUsdPriceFeed, wBTCUsdPriceFeed,) = config.activeNetworkConfig();
        ERC20Mock(wETHAddress).mint(USER, STARTING_ERC20_BALANCE); // 设置USER用户拥有10 ether 的代币初始余额
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    /**
     * 测试构造函数，tokenAddresses 和 feedAddresses 数组的长度不相同时，会引发 revert
     */
    function testRevertsIfTokenAddressLengthDoesNotMatchPriceFeedAddressLength() public {
        // Doesn't = Does not
        tokenAddresses.push(wETHAddress);
        feedAddresses.push(wETHUsdPriceFeed);
        feedAddresses.push(wBTCUsdPriceFeed); // 多一个 feedAddresses
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests ///
    //////////////////

    /**
     * 测试getUseValue函数，验证token对应的usd价格是否符合预期
     */
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(wETHAddress, ethAmount);
        console.log(expectedUsd);
        console.log(actualUsd);
        assertEq(actualUsd, expectedUsd);

        uint256 btcAmount = 15e18;
        // 15e18 * 100000 = 1,500,000e18;
        uint256 expectedBtc = 1500000e18;
        uint256 actualBtc = engine.getUsdValue(wBTCAddress, btcAmount);
        console.log(expectedBtc);
        console.log(actualBtc);
        assertEq(actualBtc, expectedBtc);
    }

    /**
     * 测试getTokenAmountFromUsd函数，验证100ether个代币数量对应的预期usd数量是否正确
     */
    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        console.log(usdAmount);
        // 2000 eth/usd -> 1 eth = 2000$
        uint256 expectedWethFromUsd = 0.05 ether;
        uint256 actualWethFromUsd = engine.getTokenAmountFromUsd(wETHAddress, usdAmount);
        assertEq(actualWethFromUsd, expectedWethFromUsd);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    /**
     * 测试depositCollateral函数存入0个抵押品，是否会抛出指定异常DSCEngine__MustBeMoreThanZero
     */
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        // ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL); // 授权engine合约 10 ether 的代币支配权
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(wETHAddress, 0);
        vm.stopPrank();
    }

    /**
     * 测试depositCollateral函数存入的抵押品不在许可范围内s_priceFeeds[token] == address(0)，会不会抛出指定异常DSCEngine__NotAllowedToken
     */
    function testRevertsWithUnapprovedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock mock = new ERC20Mock("MOCK", "MOCK", USER, AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(mock), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /**
     * 测试转账失败
     */
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.startBroadcast(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [wETHUsdPriceFeed];
        DSCEngine mockDSCEngine = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        vm.stopBroadcast();

        // Arrange - User
        vm.startPrank(USER);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDSCEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /**
     * 修饰器，授权USER用户的 engine合约 10 ether 的代币支配权，让 engine合约 质押 10 ether WETH 的代币
     */
    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL); // 授权engine合约 10 ether 的代币支配权
        engine.depositCollateral(wETHAddress, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    /**
     * 测试获取账户信息
     */
    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(wETHAddress, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    /**
     * 测试在不铸造的情况下，可以存入抵押品
     */
    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    /**
     * 测试depositCollateralAndMintDsc方法，如果健康因子被损坏，则回滚
     */
    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = AggregatorV3Interface(wETHUsdPriceFeed).latestRoundData();
        // 抵押品的花费 = (抵押品数量 * (抵押品价格 * 额外的价格精度)) / `精度
        // 抵押品的花费 = 价格 * 数量
        // 价格 = 花费 / 数量
        // 我们的目的是要求depositCollateralAndMintDsc方法回滚，健康因子应该为0.5e18，然后铸造的物品DSC，它的价格：1 DSC = 1USD
        // 铸造的DSC数量 = 铸造DSC的花费 = 抵押品的花费 = 抵押品数量 * 抵押品价格
        amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(USER);
        // 授权目标合约(engine)可以从调用者(USER)的地址中转走 AMOUNT_COLLATERAL 数量的代币
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL);
        // 健康因子, 0.5e18
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(wETHAddress, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositCollateralAndMintDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    // 存入抵押品并铸造DSC
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    // 测试铸造DSC和存入抵押品 是否成功
    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////
    // mintDsc Tests //
    ///////////////////

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [wETHAddress];
        feedAddresses = [wETHUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDSCEngine = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        // 将 mockDsc 的所有权转移到 mockDSCEngine 上面
        mockDsc.transferOwnership(address(mockDSCEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(mockDSCEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDSCEngine.depositCollateralAndMintDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    // 铸造DSC金额如果为0则回滚
    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    // 铸造DSC金额如果破坏健康因子，则回滚 insufficient allowance
    function testRevertsIfMintAmountBreaksHealthFactor() public {
        (, int256 price,,,) = AggregatorV3Interface(wETHUsdPriceFeed).latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL); // 授权engine合约 10 ether 的代币支配权
        engine.depositCollateral(wETHAddress, AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(wETHAddress, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////

    // 测试赎回抵押品
    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(wETHAddress, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // 测试redeemCollateral方法的amountCollateral为0，有无回滚
    function testRevertsRedeemCollateralIfAmountCollateralIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.redeemCollateral(wETHAddress, 0);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralBurnDsc Tests //
    ///////////////////////////////////

    // 测试赎回的抵押品数量必须大于零
    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.redeemCollateralBurnDsc(wETHAddress, 0, amountToMint);
        vm.stopPrank();
    }

    // 测试赎回已存入的抵押品，先存入抵押品，在铸造DSC，在销毁DSC，最后拿出抵押品
    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.redeemCollateralBurnDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    // 测试健康因子是否符合预期
    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        // 10 ether * 2,000 = 20,000 ether
        // 20,000 / 2 = 10,000 ether
        // 10,000 / 100 = 100 ether
        assertEq(healthFactor, expectedHealthFactor);
    }

    // 测试健康因子降到1以下
    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(wETHUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor == 0.9 ether); // 从 100 降到 0.9
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(wETHUsdPriceFeed);
        tokenAddresses = [wETHAddress];
        feedAddresses = [wETHUsdPriceFeed];
        address owner = msg.sender;

        vm.prank(owner);
        DSCEngine mockDSCEngine = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDSCEngine)); // 将 mockDsc 权限转移到 mockDSCEngine

        // Arrange - User
        vm.startPrank(USER);
        // 允许 mockDSCEngine 合约从 USER 的地址中转走最多 AMOUNT_COLLATERAL 数量的 wETH 代币
        ERC20Mock(wETHAddress).approve(address(mockDSCEngine), AMOUNT_COLLATERAL);
        mockDSCEngine.depositCollateralAndMintDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(wETHAddress).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(wETHAddress).approve(address(mockDSCEngine), collateralToCover); 
        uint256 debtToCover = 10 ether;
        mockDSCEngine.depositCollateralAndMintDsc(wETHAddress, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDSCEngine), debtToCover);
        
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(wETHUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDSCEngine.liquidate(wETHAddress, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(wETHAddress).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(wETHAddress).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(wETHAddress, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        engine.liquidate(wETHAddress, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(wETHAddress, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(wETHUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(wETHAddress).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(wETHAddress).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(wETHAddress, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.liquidate(wETHAddress, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(wETHAddress).balanceOf(liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(wETHAddress, amountToMint)
            + (
                engine.getTokenAmountFromUsd(wETHAddress, amountToMint) * engine.getLiquidationBonus()
                    / engine.getLiquidationPrecision()
            );
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the USER lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(wETHAddress, amountToMint)
            + (
                engine.getTokenAmountFromUsd(wETHAddress, amountToMint) * engine.getLiquidationBonus()
                    / engine.getLiquidationPrecision()
            );

        uint256 usdAmountLiquidated = engine.getUsdValue(wETHAddress, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            engine.getUsdValue(wETHAddress, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    ////////////////////////////////
    // View & Pure Function Tests //
    ////////////////////////////////

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = engine.getCollateralTokenPriceFeed(wETHAddress);
        assertEq(priceFeed, wETHUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], wETHAddress);
        assertEq(collateralTokens[1], wBTCAddress);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(wETHAddress, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(wETHAddress).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wETHAddress, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(wETHAddress, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
