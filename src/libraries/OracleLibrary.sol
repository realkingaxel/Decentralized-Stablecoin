// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

/**
 * @title Oracle Library
 * @author Axel Valavaara
 * @notice This library is used to check for stale data
 * we want Engine to freeze if price is stale
 */
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    
    error OracleLibrary__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
       (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

       uint256 timeSinceLastUpdate = block.timestamp - updatedAt;

         if (timeSinceLastUpdate > TIMEOUT) {
              revert OracleLibrary__StalePrice();
         }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
