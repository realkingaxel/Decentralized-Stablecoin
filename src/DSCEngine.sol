// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLibrary.sol";

/**
 * @title DSCEngine
 * @author Axel Valavaara
 * @notice
 * System is designed to be very minimal. Tokens maintain a 1:1 peg with USD.
 * This stablecoin has the following properties:
 * - Exogenous Collateral (WETH, WBTC)
 * - Algorithmic Supply Control
 * - Pegged to USD
 *
 * Our system should always be overcollateralized. At no point should the <= the value of all the DSC.
 *
 * This contract is similar to DAI if DAI had no fees,
 * no governance, and was only backed by WETH and WBTC.
 *
 * @notice Contract is core of the DSC system.
 *  Handles all logic for minting and redeeming DSC.
 * Also depositing & withdrawing collateral.
 * @notice this contract is very Loosly based on the MakerDAO DSS (DAI Stablecoin System).
 */
contract DSCEngine is ReentrancyGuard {
    /* Errors */
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__tokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferOfCollateralFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__TransferOfBurnFailed();
    error DSCEngine__HealthFactorNotBroken();
    error DSCEngine__HealthFactorNotImproved();

    /* Types */
    using OracleLib for AggregatorV3Interface;

    /* State Variables */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address token => address priceFeed) s_priceFeeds; // token address -> price feed address
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // user address -> (token address -> amount)
    mapping(address user => uint256 amountDscMinted) private s_dscMinted; // user address -> amount of DSC minted
    address[] private s_collateralTokens; // array of collateral token addresses
    DecentralizedStableCoin private immutable i_dsc;

    /* Events */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);
    /* Modifiers */

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /* External Functions */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__tokenAddressAndPriceFeedAddressMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }
    /**
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     * @param amountDscToMint the amount of DSC to mint
     * @notice this will deposit collateral and mint DSC in one transaction
     * notice this function is more gas efficient than calling the other two functions separately
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
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // transfer collateral
        // update internal accounting
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferOfCollateralFailed();
        }
    }

    //in order to redeem collateral
    // 1. helath factor must be over 1 after collateral withdrawn

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    //

    // check if collateral is > over DSC amount

    /**
     * @notice follows CEI (checks-effects-interactions) pattern
     * @param amountDscToMint the amount of DSC to mint
     * notice must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        // if mint too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @param tokenCollateralAddress the address of the token to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDscToBurn the amount of DSC to burn
     * @notice this will redeem collateral and burn DSC in one transaction
     * notice this function is more gas efficient than calling the other two functions separately
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral checks heath factor
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param collateral the address of the collateral to liquidate
     * @param user The adddress of the user who has broken MIN_HEALTH_FACTOR
     * @param debtToCover amount of DSC you want to burn to improve the health factor
     * @notice you can partially liquidate a user's position
     * @notice you will get liquidation bonus for taking the users collateral
     * @notice this function assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * notice if protocol is undercollateralized, we wouldnt be able to incentivize liquidators
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotBroken();
        }
        // Give them 10% bonus
        // not 1 for 1 then there is no incentive
        // so for example if liquidate 100$ DSC get 110$ worth of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 liquidationBonus = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + liquidationBonus;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /* Private and Internal Functions */

    /**
     * @dev this is internal low level function do not let anyone call without checking health factor after.
     */
    function _burnDsc(uint256 amount, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferOfBurnFailed();
        }
        i_dsc.burn(amount);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferOfCollateralFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * @notice returns how close to liquidation a user is
     * if a user goes below 1, they can be liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        // get total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);

        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check if they have enough collateral (helth factor)
        // 2. if not, revert
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    /* public and external functions */

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1eth = 2000 USD
        // return data will be 2000 * 1e8
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            // convert that amount to USD value
            // add it to the total collateral value
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1eth = 2000 USD
        // return data will be 2000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address token, address user) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
