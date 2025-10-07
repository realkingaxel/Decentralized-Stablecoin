// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console2, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";
import {console2} from "forge-std/console2.sol";

contract InvariantsTest is StdInvariant, Test {
    DSCEngine dscEngine;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;

    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreCollateralValueThanTotalSupply() public view {
        uint256 totalSupplyWeth = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalSupplyWbtc = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 wethValue = dscEngine.getUsdValue(weth, totalSupplyWeth);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalSupplyWbtc);

        uint256 totalSupplyDsc = dsc.totalSupply();
        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", wbtcValue);
        console.log("totalSupplyDsc: ", totalSupplyDsc);
        console.log("timesDepositCalled: ", handler.timesDepositCalled());
        console.log("timesMintcalled: ", handler.timesMintcalled());
        console.log("timesRedeemCalled: ", handler.timesRedeemCalled());
        assert(wethValue + wbtcValue >= totalSupplyDsc);
    }
}
