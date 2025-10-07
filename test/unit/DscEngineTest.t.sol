// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {console} from "forge-std/console.sol";

contract DscEngineTest is Test {
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address user = makeAddr("user");
    address liquidator = makeAddr("liquidator");
    uint256 constant AMOUNT_COLLATERAL = 10 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(user, STARTING_BALANCE);
    }

    //////////////////////////////////////
    //        Constructor Tests           //
    //////////////////////////////////////
    address[] public priceFeedAddresses;
    address[] public tokenAddresses;

    function testRevertsIfTokenLenghtDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__tokenAddressAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////////////////////
    //        Price Feed Tests           //
    //////////////////////////////////////

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // 100e18 / 2000 = 0.05e18
        uint256 expectedEth = 0.05 ether;
        uint256 actualEth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedEth, actualEth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 / 1e18 = 30000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    //////////////////////////////////////
    //        Deposit Collateral Tests    //
    //////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testIfRevertsWhenCollateralTokenNotAllowed() public {
        ERC20Mock ranToken = new ERC20Mock("rantoken", "RAN", user, AMOUNT_COLLATERAL);
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);

        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(expectedDscMinted, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralAmount);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, false, address(dscEngine));
        emit CollateralDeposited(user, weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testMintAndDepositCollateral() public {
        vm.startPrank(user);
        uint256 amountToMint = 50e18;
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 depositedCollateralValue) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralAmount = dscEngine.getTokenAmountFromUsd(weth, depositedCollateralValue);
        assertEq(totalDscMinted, amountToMint);
        assertEq(expectedCollateralAmount, AMOUNT_COLLATERAL);
    }
    //////////////////////////////////////
    //        Mint Dsc Tests             //
    //////////////////////////////////////

    function testMintUpdatesBalance() public depositedCollateral {
        vm.startPrank(user);
        uint256 amountToMint = 50e18;
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint);
    }

    function testMintFailsIfBreaksHealthFactor() public depositedCollateral {
        vm.startPrank(user);
        uint256 amountToMint = 15000e18;
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    //////////////////////////////////////
    //        Redeem Collateral Tests     //
    //////////////////////////////////////
    modifier mintedDsc() {
        vm.startPrank(user);
        uint256 amountToMint = 500e18;
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
        _;
    }

    function testRedeemCollateralUpdatestBalanceCorrectly() public depositedCollateral mintedDsc {
        vm.startPrank(user);
        uint256 amountToRedeem = 5e18;
        dscEngine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 collateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        uint256 expectedCollateralAmount = AMOUNT_COLLATERAL - amountToRedeem;
        uint256 expectedDscMinted = 500e18;

        assertEq(collateralAmount, expectedCollateralAmount);
        assertEq(totalDscMinted, expectedDscMinted);
    }

    function testRedeemCollateralRevertsIfBreaksHealthFactor() public depositedCollateral mintedDsc {
        vm.startPrank(user);
        uint256 amountToRedeem = 9.6e18;
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralForDsc() public depositedCollateral mintedDsc {
        vm.startPrank(user);
        uint256 amountToRedeem = 5e18;
        uint256 amountToBurn = 250e18;
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.redeemCollateralForDsc(weth, amountToRedeem, amountToBurn);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 collateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        uint256 expectedCollateralAmount = AMOUNT_COLLATERAL - amountToRedeem;
        uint256 expectedDscMinted = 500e18 - amountToBurn;
        uint256 userBalance = dsc.balanceOf(user);
        uint256 userEthBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(collateralAmount, expectedCollateralAmount);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(userBalance, amountToBurn);
        assertEq(userEthBalance, amountToRedeem);
    }

    //////////////////////////////////////
    //        Burn DSC Tests             //
    //////////////////////////////////////

    function testBurnDsc() public depositedCollateral mintedDsc {
        vm.startPrank(user);
        uint256 amountToBurn = 200e18;
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDSC(amountToBurn);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 collateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        uint256 expectedCollateralAmount = AMOUNT_COLLATERAL;
        uint256 expectedDscMinted = 500e18 - amountToBurn;

        assertEq(collateralAmount, expectedCollateralAmount);
        assertEq(totalDscMinted, expectedDscMinted);
    }

    /////////////////////////////////////
    //        Liquidate Tests            //
    //////////////////////////////////////

    function testLiquidateRevertsIfHealthFactorOverOne() public depositedCollateral {
        vm.startPrank(liquidator);
        ERC20Mock(weth).mint(liquidator, AMOUNT_COLLATERAL);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotBroken.selector);
        dscEngine.liquidate(user, weth, 10e18);
        vm.stopPrank();
    }

    function testCanLiquidate() public depositedCollateral mintedDsc {
        // make price drop
        uint256 amountToCover = 250e18;

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(99e8);

        console.log(MockV3Aggregator(wethUsdPriceFeed).latestAnswer());

        vm.prank(address(dscEngine));
        dsc.mint(liquidator, amountToCover);

        vm.prank(liquidator);
        dsc.approve(address(dscEngine), amountToCover);

        vm.prank(liquidator);
        dscEngine.liquidate(weth, user, amountToCover);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 collateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assert(AMOUNT_COLLATERAL > collateralAmount);
        assertEq(totalDscMinted, 250e18);
    }

    function testLiquidaterevertsIfHealthFactorNotImproved() public depositedCollateral mintedDsc {
        // make price drop
        uint256 amountToCover = 250e18;

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(50e8);

        vm.prank(address(dscEngine));
        dsc.mint(liquidator, amountToCover);

        vm.prank(liquidator);
        dsc.approve(address(dscEngine), amountToCover);

        vm.prank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dscEngine.liquidate(weth, user, amountToCover);
    }

    /////////////////////////////////////
    //        getter function Tests       //
    //////////////////////////////////////

    function testgetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = 20000e18;
        // 10 ETH * 2000 = 20000e18
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetHealthFactor() public depositedCollateral mintedDsc {
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        //
        uint256 expectedHealthFactor = 20e18;
        assertEq(healthFactor, expectedHealthFactor);
    }
}
