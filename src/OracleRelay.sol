// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";
import {IChainlinkAggregatorV3} from "./interfaces/IChainlinkAggregator.sol";

/// @title OracleRelay
/// @notice Single-feed AggregatorV3-compatible relay. A trusted writer republishes one source
///         feed's latest round verbatim. Latest-round compatibility only, no round history.
contract OracleRelay is IChainlinkAggregatorV3, Ownable, Initializable {
    error Access();
    error InvalidWriter();
    error NoRoundData();
    error FutureTimestamp();

    struct RoundData {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 roundId;
        uint80 answeredInRound;
        uint64 relayedAt;
        bool available;
    }

    address public writer;
    uint8 private _decimals;
    string private _description;
    RoundData private _round;

    event Initialized(address indexed owner, address indexed writer, uint8 decimals, string description);
    event WriterUpdated(address indexed oldWriter, address indexed newWriter);
    event RoundDataUpdated(
        uint80 indexed roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound,
        uint64 relayedAt
    );
    event RoundDataInvalidated(uint80 indexed roundId, uint64 relayedAt);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address writer_, uint8 decimals_, string calldata description_)
        external
        initializer
    {
        if (owner_ == address(0)) revert NewOwnerIsZeroAddress();
        if (writer_ == address(0)) revert InvalidWriter();
        _initializeOwner(owner_);
        writer = writer_;
        _decimals = decimals_;
        _description = description_;
        emit Initialized(owner_, writer_, decimals_, description_);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function relayedAt() external view returns (uint64) {
        return _round.relayedAt;
    }

    function hasRoundData() external view returns (bool) {
        return _round.available;
    }

    function setWriter(address writer_) external onlyOwner {
        if (writer_ == address(0)) revert InvalidWriter();
        address oldWriter = writer;
        writer = writer_;
        emit WriterUpdated(oldWriter, writer_);
    }

    /// @notice Atomically rotates the writer and makes the stored round unreadable.
    function invalidate(address replacementWriter_) external onlyOwner {
        if (replacementWriter_ == address(0)) revert InvalidWriter();
        address oldWriter = writer;
        writer = replacementWriter_;
        _round.available = false;
        emit WriterUpdated(oldWriter, replacementWriter_);
        emit RoundDataInvalidated(_round.roundId, _round.relayedAt);
    }

    function updateRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external {
        if (msg.sender != writer) revert Access();
        if (updatedAt > block.timestamp) revert FutureTimestamp();

        uint64 relayedAt_ = uint64(block.timestamp);
        _round = RoundData({
            answer: answer,
            startedAt: startedAt,
            updatedAt: updatedAt,
            roundId: roundId,
            answeredInRound: answeredInRound,
            relayedAt: relayedAt_,
            available: true
        });

        emit RoundDataUpdated(roundId, answer, startedAt, updatedAt, answeredInRound, relayedAt_);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return _readRound();
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (!_round.available || roundId != _round.roundId) revert NoRoundData();
        return _readRound();
    }

    function _readRound() internal view returns (uint80, int256, uint256, uint256, uint80) {
        RoundData storage round = _round;
        if (!round.available) revert NoRoundData();
        return (round.roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    function supportsInterface(bytes4 _sum) public pure returns (bool) {
        return _sum == 0x01ffc9a7 || _sum == 0x7f5828d0 || _sum == 0x73851258;
    }
}
