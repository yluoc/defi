//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * this system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * this stablecoin has the properties:
 *     exogenous collateral
 *     dollar pegged
 *     algorithmically stable
 * it is similiar to DAI without governance, no fees, and backed by wETH and wBTC.
 * the DSC System should always be "overcollateralized", at no point, should the value of all collateral <= the $ backed value of all the DSC.
 * @notice this contract is the core of DSC System, it handles all logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice this contract is based on MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    // errors
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressAndPriceAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 HealthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImprove();

    using OracleLib for AggregatorV3Interface;

    // state variables
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTHFACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collaterTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollaterRedeemed(address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount);

    // modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // constructors
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD price feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceAddressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collaterTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // external functions
    /**
     * @param tokenCollateralAddress: the address of the deposit as collateral
     * @param amountCollateral: the amount of collateral to deposit
     * @param amountDscToMint: the amount of decenteralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress: the address of the token to deposit as collateral
     * @param amountCollateral: the amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress: the collateral address to redeem
     * @param amountCollateral: the amount of collateral to redeem
     * @param amountDscToBurn: the amount of DSC to burn
     * @notice this function burns DSC and underlying collateral in one transaction.
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param ammountDscToMint: the amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDSC(uint256 ammountDscToMint) public moreThanZero(ammountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += ammountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, ammountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // if someone is almost undercollateralized, we will pay you to liquidate them.
    /**
     * @param collateral: the ERC20 collateral address to liquidate from the user
     * @param user: the user who has broken the health factor
     * @param debtToCover: the amount of DSC to burn to improve the users health factor
     * @notice you can partially liquidate a user and get a liquidation bonus for taking the users funds
     * @notice this function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice a known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive(e.g: 10% bonus) the liquidators.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startUserHealthFactor = _healthFactor(user);
        if (startUserHealthFactor >= MIN_HEALTHFACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // bonus feature.
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endUserHealthFactor = _healthFactor(user);
        if (endUserHealthFactor <= startUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImprove();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // internal functions
    /**
     * @dev low-level internal function, do not call unless the function calling it is checking for health factors being broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollaterRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValued(user);
    }
    /**
     * returns how close to liquidation a user is;
     * if a user goes below 1, then they can get liquidated.
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralVlaueInUse) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralVlaueInUse * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    /**
     * @notice check health factor if they have enough collateral.
     */

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 useHealthFactor = _healthFactor(user);
        if (useHealthFactor < MIN_HEALTHFACTOR) {
            revert DSCEngine__BreaksHealthFactor(useHealthFactor);
        }
    }

    // view & pure function
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValued(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collaterTokens.length; i++) {
            address token = s_collaterTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collaterTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
