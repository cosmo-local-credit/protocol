// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "src/interfaces/IChainlinkAggregator.sol";

contract MockChainlinkAggregator is IChainlinkAggregatorV3 {
    uint8 private _decimals;
    string private _description;
    uint256 private _version;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, string memory description_, int256 answer_) {
        _decimals = decimals_;
        _description = description_;
        _version = 1;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external view returns (uint256) {
        return _version;
    }

    function getRoundData(
        uint80 /* _roundId */
    )
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, _answer, block.timestamp, _updatedAt, 0);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, block.timestamp, _updatedAt, 0);
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }
}
