//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @notice this library is used to check the Chainlink Oracle for stale data.
 * @notice if a price is stale, the function will revert and render the DSCEngine unusable (this is by design)
 * @notice we want the DSCEngine to freeze if price become stale.
 */
library OracleLib {
    error OracleLib_StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib_StalePrice();
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getTimeout(AggregatorV3Interface /* chainlinkFeed */ ) public pure returns (uint256) {
        return TIMEOUT;
    }
}
