// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {FailedTransferFromMock} from "../../test/mocks/FailedTransferFromMock.sol";
import {FailedMintDscMock} from "../../test/mocks/FailedMintDscMock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public config;
    address public weth;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;

    address public USER = makeAddr("user");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 private constant PRECISION = 1e18;
    uint256 public amountToMint = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    //////////////////////

    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public view {
        // 15e18 * 2,000/ETH = 30,000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, 100e18);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    function testRevertIfTransferFromFails() public {
        //Arrange
        FailedTransferFromMock failedTransferFromToken =
            new FailedTransferFromMock("FailToken", "FT", USER, AMOUNT_COLLATERAL);
        address failedTransferFromTokenPriceFeed = ethUsdPriceFeed;
        dsce.addAllowedToken(address(failedTransferFromToken), failedTransferFromTokenPriceFeed);
        vm.startPrank(USER);
        failedTransferFromToken.approve(address(dsce), AMOUNT_COLLATERAL);

        //Act
        //Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositCollateral(address(failedTransferFromToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // depositCollateralAndMint Tests //
    ///////////////////////////////////

    function testRevertsIfMintingDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        console.log(price); // 200000000000
        // (10e18 * (200000000000 * 1e10))/1e18
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        console.log(amountToMint); // 20000.000000000000000000
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 collateralUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL); // ((2000 * 1e10) * 10e18) / 10e18
        console.log(collateralUsd);

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, collateralUsd);
        console.log(expectedHealthFactor);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        _;
    }

    function testMintPossibleWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////
    // mintDSC Tests //
    //////////////////

    function testRevertsIfMintDscFails() public {
        FailedMintDscMock mockDsc = new FailedMintDscMock();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);

        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    ///////////////////
    // burnDsc Tests //
    //////////////////

    function testRevertsIfBurnAmountIsZero() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);

        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsc.approve(address(dsce), amountToMint);

        // Act
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        // Assert
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ///////////////////////////

    function testCanRedeemCollateral() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Act
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);

        // Assert
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        console.log(userBalance);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemed() public depositedCollateral {
        vm.expectEmit(true, true, true, false, address(dsce));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////////////////////
    // redeemCollateralForDsc Tests //
    /////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    /////////////////////////
    // healthFactor Tests ///
    ////////////////////////

    function testGetCorrectHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        vm.startPrank(USER);
        uint256 actualHealthFActor = (dsce.getHealthFactor(USER));
        assertEq(expectedHealthFactor, actualHealthFActor);
        vm.stopPrank();
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 healthFactor = dsce.getHealthFactor(USER);
        //console.log(healthFactor);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        // Arrange
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        //uint256 healthFactor = dsce.getHealthFactor(USER);
        //console.log(healthFactor);
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        console.log(liquidatorWethBalance);
        uint256 liquidationBonus = (dsce.getTokenAmountFromUsd(weth, amountToMint)) / dsce.getLiquidationBonus();
        console.log(liquidationBonus);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint) + liquidationBonus;
        console.log(expectedWeth);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    ////////////////////////////////
    // View & Pure Function Tests //
    ///////////////////////////////

    function testgetHealthFactor() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        assert(userHealthFactor != 0);
        vm.stopPrank();
    }

    function testGetPrecision() public view {
        uint256 precision = dsce.getPrecision();
        assertEq(precision, PRECISION);
    }

    function testGetAccountInformation() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        (uint256 totalDscMinted, uint256 collateralValueInUSd) = dsce.getAccountInformation(USER);
        ERC20Mock(weth).approve(address(dsc), AMOUNT_COLLATERAL);
        uint256 expectedCollateralValueInUSd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        dsc.approve(address(dsc), amountToMint);
        uint256 expectedTotalDscMinted = dsc.balanceOf(USER);

        assertEq(collateralValueInUSd, expectedCollateralValueInUSd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        vm.stopPrank();
    }
}
