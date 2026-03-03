// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IQuoter} from "./interfaces/IQuoter.sol";
import {IChainlinkAggregatorV3} from "./interfaces/IChainlinkAggregator.sol";
import {IERC20Meta} from "./interfaces/IERC20Meta.sol";

contract OracleQuoter is IQuoter, Ownable, Initializable {
    error TokenCallFailed();
    error OracleNotSet(address token);
    error OracleCallFailed(address oracle, string reason);
    error InvalidOraclePrice(address oracle);
    error StaleOraclePrice(address oracle);
    error InvalidBaseCurrency();
    error InvalidToken();
    error InvalidDecimals(uint8 decimals);

    uint256 private constant DEFAULT_MAX_STALENESS = 86400; // 1 day

    mapping(address => address) public oracles;
    address public baseCurrency;
    uint256 public maxStaleness;

    event Initialized(address indexed owner, address indexed baseCurrency);
    event OracleUpdated(address indexed token, address indexed oracle);
    event OracleRemoved(address indexed token);
    event MaxStalenessUpdated(uint256 maxStaleness);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner, address _baseCurrency) external initializer {
        if (_baseCurrency == address(0)) revert InvalidBaseCurrency();
        _initializeOwner(owner);
        baseCurrency = _baseCurrency;
        maxStaleness = DEFAULT_MAX_STALENESS;
        emit Initialized(owner, _baseCurrency);
    }

    function setMaxStaleness(uint256 _maxStaleness) public onlyOwner {
        maxStaleness = _maxStaleness;
        emit MaxStalenessUpdated(_maxStaleness);
    }

    function setOracle(address token, address oracleAddress) public onlyOwner {
        if (token == address(0) || oracleAddress == address(0)) revert InvalidToken();
        oracles[token] = oracleAddress;
        emit OracleUpdated(token, oracleAddress);
    }

    function removeOracle(address token) public onlyOwner {
        delete oracles[token];
        emit OracleRemoved(token);
    }

    function valueFor(address _outToken, address _inToken, uint256 _value) public view returns (uint256) {
        uint8 dout;
        uint8 din;

        try IERC20Meta(_outToken).decimals() returns (uint8 decimals_) {
            dout = decimals_;
        } catch {
            revert TokenCallFailed();
        }

        try IERC20Meta(_inToken).decimals() returns (uint8 decimals_) {
            din = decimals_;
        } catch {
            revert TokenCallFailed();
        }

        (uint256 inRate, uint8 inRateDecimals) = getOracleRate(_inToken);
        (uint256 outRate, uint8 outRateDecimals) = getOracleRate(_outToken);

        return determineOutput(_value, din, dout, inRate, inRateDecimals, outRate, outRateDecimals);
    }

    function getOracleRate(address token) internal view returns (uint256 rate, uint8 rateDecimals) {
        address oracle = oracles[token];
        if (oracle == address(0)) revert OracleNotSet(token);

        try IChainlinkAggregatorV3(oracle).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) revert InvalidOraclePrice(oracle);
            if (block.timestamp - updatedAt > maxStaleness) revert StaleOraclePrice(oracle);
            rate = uint256(answer);
        } catch Error(string memory reason) {
            revert OracleCallFailed(oracle, reason);
        } catch {
            revert OracleCallFailed(oracle, "latestRoundData call failed");
        }

        try IChainlinkAggregatorV3(oracle).decimals() returns (uint8 decimals_) {
            rateDecimals = decimals_;
        } catch Error(string memory reason) {
            revert OracleCallFailed(oracle, reason);
        } catch {
            revert OracleCallFailed(oracle, "decimals call failed");
        }
    }

    function determineOutput(
        uint256 inputValue,
        uint8 inTokenDecimals,
        uint8 outTokenDecimals,
        uint256 inRate,
        uint8 inRateDecimals,
        uint256 outRate,
        uint8 outRateDecimals
    ) internal pure returns (uint256) {
        uint256 outScale = getScale(outTokenDecimals);
        uint256 inScale = getScale(inTokenDecimals);
        uint256 outRateScale = getScale(outRateDecimals);
        uint256 inRateScale = getScale(inRateDecimals);

        return
            FixedPointMathLib.fullMulDiv(inputValue, inRate * outScale * outRateScale, inRateScale * inScale * outRate);
    }

    function getScale(uint8 decimals) internal pure returns (uint256) {
        if (decimals > 77) revert InvalidDecimals(decimals);
        return 10 ** uint256(decimals);
    }

    function supportsInterface(bytes4 _sum) public pure returns (bool) {
        if (_sum == 0x01ffc9a7) {
            return true;
        }
        if (_sum == 0x9493f8b2) {
            return true;
        }
        if (_sum == 0xdbb21d40) {
            return true;
        }
        return false;
    }
}
