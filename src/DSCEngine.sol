//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine，DSC引擎
 * @author Lotus
 * The system is designed to be as minimal as possible, and have the tokens maintain 1 DSC token == $1 peg.
 * This stablecoin has the properties:
 * - Collateral: External (wETH & wBTC)
 * - Minting: Algorithmic
 * - Relative Stability: Pegged / Anchored to USD
 *
 * It is similar to DAI, DAI has no governance, no fees, and was only backed by WETH and WBTC.
 * DSC：Decentralized Smart Contract
 * Out DSC system should always be "overCollateral". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////
    // Errors //
    ////////////

    error DSCEngine__MustBeMoreThanZero(); // 必须大于零
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength(); // 代币地址和价格预言机地址的长度必须相同
    error DSCEngine__NotAllowedToken(); // 不允许的代币地址tokenAddress，该tokenAddress对应的价格数据源不允许抵押
    error DSCEngine__TransferFailed(); // 转账失败
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor); // 损坏的健康因子（healthFactor < 1e18）
    error DSCEngine__MintFailed(); // DSC铸造失败
    error DSCEngine__HealthFactorOK(); // 健康因子正常
    error DSCEngine__HealthFactorNotImproved(); // 健康因子未改善

    //////////
    // Type //
    //////////

    using OracleLib for AggregatorV3Interface;

    /////////////////////
    // State Variables //
    /////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // additional feed precision，额外的价格精度
    uint256 private constant PRECISION = 1e18; // 精度
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 清算阈值, (over collateralize, 超额抵押200%，质押的抵押物需要比铸造的DSC多一倍)
    uint256 private constant LIQUIDATION_PRECISION = 100; // 清算精度
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 最小健康因子
    uint256 private constant LIQUIDATION_BONUS = 10; // 清算奖金, This means a 10% bonus

    // mapping(address => bool) private s_tokenToAllowed; // 允许的token
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed，token地址 映射到 价格数据源
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // 已存入的抵押物
    mapping(address user => uint256 amountDscMinted) private s_DesMinted; // 用户 对应 已铸造的DSC总额
    address[] private s_collateralTokens; // 抵押代币地址数组
    DecentralizedStableCoin private immutable i_dsc; // i_dsc 代表 DSC 代币合约的实例，所有 ERC20 相关操作都要通过它来完成。

    ////////////
    // Events //
    ////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount); // 存入抵押品
    event CollateralRedeem(address indexed from, address indexed to, address indexed token, uint256 amount); // 赎回抵押品

    ///////////////
    // Modifiers //
    ///////////////

    // 金额必须大于0
    modifier moreThenZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    // 允许抵押的代币地址tokenAddress
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        uint256 length = tokenAddresses.length;
        if (length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // 设置 token地址 到 价格数据源，ETH/USD, BTC/USD, MKR/USD，如果有价格数据源，那么就允许使用该种类为抵押品
        for (uint256 i = 0; i < length; ++i) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * 存入抵押品并铸造DSC
     * @notice This function will deposit your collateral and mint DSC in one transaction.
     * @param tokenCollateralAddress The address of the token to deposit as collateral 作为抵押品存入的代币地址
     * @param amountCollateral The amount of the collateral to deposit 存入抵押品的数量
     * @param amountDscToMint The amount of DSC to mint 铸造的DSC数量
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * 存入抵押品
     * @notice follows CEI，遵循CEI(Checks - Effects - Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral 作为抵押品存入的代币地址
     * @param amountCollateral The amount of the collateral to deposit 存入抵押品的数量
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThenZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        // user (msg.sender) transfer amountCollateral to this contract (address(this))
        // 用户 转账 抵押品数量 到 该合约地址
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * 赎回抵押品以销毁DSC
     * @param tokenCollateralAddress The address of the token to redeem as collateral 赎回抵押品的代币地址
     * @param amountCollateral The amount of the collateral to redeem 赎回抵押品的数量
     * @param amountDscToBurn This is the amount of DSC to burn 这是需要被销毁的DSC数量
     */
    function redeemCollateralBurnDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * 赎回抵押品
     * @param tokenCollateralAddress The address of the token to redeem as collateral 赎回抵押品的代币地址
     * @param amountCollateral The amount of the collateral to redeem 赎回抵押品的数量
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThenZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * 铸造DSC
     * @notice follows CEI，遵循CEI(Checks - Effects - Interactions)
     * @notice they must have more collateral value than the minimum threshold, otherwise it will be revert
     * @param amountDscToMint The amount of DSC to mint 铸造的DSC数量
     */
    function mintDsc(uint256 amountDscToMint) public moreThenZero(amountDscToMint) nonReentrant {
        s_DesMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * 销毁DSC
     * @param amountDscToBurn This is the amount of DSC to burn 这是需要销毁的DSC数量
     */
    function burnDsc(uint256 amountDscToBurn) public moreThenZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    /**
     * 清算
     * @param collateral The collateral address (ERC20 Type) to liquidate from the user 从用户中清算的抵押品地址（ERC20类型）
     * @param user The user who has broken the health factor. Their _healthFactor should by below MIN_HEALTH_FACTOR 用户的健康因子已被破坏，它的健康因子小于MIN_HEALTH_FACTOR
     * @param amountDebtToCover The amount of DSC you want to burn to improve the users health factor 为了提高用户的健康因子，需要销毁的DSC数量，偿还债务金额
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice This function working assumes the protocol will be roughly 200% over over collateralize in order for this to work.
     * @notice A know bug would be if the protocol were 100% or less collateralize, then we wouldn't be able to incentive the liquidators. For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 amountDebtToCover)
        external
        moreThenZero(amountDebtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }
        // We want to burn their DSC "debt", And take their collateral
        // 质押collateral数量     铸造的DSC数量，债务amountDebt      ETH和DSC的价格比率   健康因子healthFactor                               清算状态
        // 200ETH(200DSC)     ->  100DSC                            100ETH = 100DSC      ((200DSC * 50 / 100) * 1e18) / 100DSC = 1e18       不可清算
        // 200ETH(160DSC)     ->  100DSC                            100ETH = 80DSC       ((160DSC * 50 / 100) * 1e18) / 100DSC = 0.8e18     可清算
        // 偿还100DSC的债务，也就是125ETH，然后获得200ETH，赚了75ETH(60DSC)
        // 100dsc -> 100usd -> ?eth (100eth = 80usd) -> ? = 100 * 100 /80
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, amountDebtToCover); //
        // And give them a 10% bonus, So we are giving the liquidator $110 of WETH for 100 DSC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // 额外的抵押品
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(amountDebtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 获得健康因子
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256 healthFactor)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // 获取账户信息，包括已铸造的DSC总额和抵押品价值
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /**
     * 获取账户抵押品价值
     * @param user The address of the user to get the collateral value for 获取抵押品价值的用户地址
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        uint256 length = s_collateralTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    // 根据token地址和amount数量，获得USD价格
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000
        // The returned price value from Chainlink will be 1000 *1e8
        // (1000 * 1e8 * 1e10) * 1000 * 1e18 = x * 1e36，所有要除以1e18
        // amount的精度是1e18，因为ERC20的精度是1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * 根据指定的美元价值（以 Wei 为单位），计算用户需要多少数量的指定代币才能达到该价值
     * @param token 目标代币的地址，用于查询其对应的预言机价格源
     * @param usdAmountInWei 以 Wei 为单位的美元金额（1 USD = 1e18 Wei），表示需要转换的美元价值
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData(); // 2000e8
        // 100DSC = 100$ = ??? ETH
        // 1ETH = 2000$
        // 2000 eth/usd -> 2000/1 = eth/usd -> eth = 2000usd -> 1eth=2000$
        // price = 2000$ * 1e8
        // usdAmountInWei = 100$ * 1e18
        // ??? = 100$ / 2000$ = 0.05 = (100$ * 1e18 * 1e18) / (2000$ * 1e8 * 1e10) = 0.05 * 1e18
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // 如果健康因子被损坏(healthFactor < 1)，则回滚
    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /**
     * 获取抵押物的健康因子
     * @param totalDscMinted 铸造的DSC总量
     * @param collateralValueInUsd 用户抵押品的总价值（以 USD 计价）
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256 healthFactor)
    {
        if (totalDscMinted == 0) return type(uint256).max; // 如果没有铸造DSC，那么健康因子为uint256的最大值，也就是2^256 - 1
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * 计算健康因子
     * @notice Returns how close to liquidation a user is
     * @notice If a user goes below 1, then they can get liquidated
     * @param user The address of the user to calculate the health factor for 要计算健康因子的用户地址
     * @return healthFactor The health factor of the user 用户的健康因子
     */
    function _healthFactor(address user) private view returns (uint256 healthFactor) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * 获取账户信息，包括已铸造的DSC总额和抵押品价值
     * @param user Get the user address of the account information 获取账户信息的用户地址
     * @return totalDscMinted 已铸造的DSC总额
     * @return collateralValueInUsd 抵押品价值（USD）
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DesMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * 赎回抵押品
     * @param tokenCollateralAddress The address of the token to redeem as collateral 赎回抵押品的代币地址
     * @param amountCollateral The amount of the collateral to redeem 赎回抵押品的数量
     * @param from The address of the collateral to source 抵押物来源的地址
     * @param to The address of the collateral to receiver 抵押物接收方的地址
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; // 如果质押的代币余额不足以取出完成赎回，那么则会自动触发回滚
        emit CollateralRedeem(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * 销毁DSC
     * @param amountDscToBurn This is the amount of DSC to burn 这是需要销毁的DSC数量
     * @param onBehalfOf The address to destroy the total amount of minted DSC token 销毁已铸造DSC总额的地址（销毁的DSC代币是谁的）
     * @param dscFrom The address providing the DSC token 提供DSC代币的地址（谁提供被销毁的DSC代币）
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DesMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
