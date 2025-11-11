// Author: Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";
import {IQuoter} from "./interfaces/IQuoter.sol";

contract RelativeQuoter is IQuoter, Ownable, Initializable {
    error TokenCallFailed();

    uint256 private constant PPM = 1_000_000;

    mapping(address => uint256) public priceIndex;

    event PriceIndexUpdated(address indexed tokenAddress, uint256 exchangeRate);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        _initializeOwner(owner);
    }

    function setPriceIndexValue(
        address _tokenAddress,
        uint256 _exchangeRate
    ) public onlyOwner returns (uint256) {
        priceIndex[_tokenAddress] = _exchangeRate;
        emit PriceIndexUpdated(_tokenAddress, _exchangeRate);
        return _exchangeRate;
    }

    // Implements IQuoter
    function valueFor(
        address _outToken,
        address _inToken,
        uint256 _value
    ) public returns (uint256) {
        uint8 dout;
        uint8 din;
        bool r;
        bytes memory v;

        uint256 inExchangeRate = PPM;
        uint256 outExchangeRate = PPM;

        if (priceIndex[_inToken] > 0) {
            inExchangeRate = priceIndex[_inToken];
        }

        if (priceIndex[_outToken] > 0) {
            outExchangeRate = priceIndex[_outToken];
        }

        (r, v) = _outToken.call(abi.encodeWithSignature("decimals()"));
        if (!r) revert TokenCallFailed();
        dout = abi.decode(v, (uint8));

        (r, v) = _inToken.call(abi.encodeWithSignature("decimals()"));
        if (!r) revert TokenCallFailed();
        din = abi.decode(v, (uint8));

        if (din == dout) {
            return determineOutput(_value, inExchangeRate, outExchangeRate);
        }

        uint256 d = din > dout ? 10 ** ((din - dout)) : 10 ** ((dout - din));
        if (din > dout) {
            return determineOutput(_value / d, inExchangeRate, outExchangeRate);
        } else {
            return determineOutput(_value * d, inExchangeRate, outExchangeRate);
        }
    }

    function determineOutput(
        uint256 inputValue,
        uint256 inExchangeRate,
        uint256 outExchangeRate
    ) internal pure returns (uint256) {
        return (inputValue * inExchangeRate) / outExchangeRate;
    }

    // Implements EIP165
    function supportsInterface(bytes4 _sum) public pure returns (bool) {
        if (_sum == 0x01ffc9a7) {
            // ERC165
            return true;
        }
        if (_sum == 0x9493f8b2) {
            // ERC173
            return true;
        }
        if (_sum == 0xdbb21d40) {
            // TokenQuote
            return true;
        }
        return false;
    }
}
