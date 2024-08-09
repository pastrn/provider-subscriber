// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract AggregatorMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
    external
    pure
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        return (0, 100000000, 0, 0, 0);
    }
}