// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IQuoter} from "./interfaces/IQuoter.sol";
import {IERC20Meta} from "./interfaces/IERC20Meta.sol";

contract DecimalQuoter is IQuoter {
    error TokenCallFailed();

    function valueFor(address outToken, address inToken, uint256 value) external view override returns (uint256) {
        uint8 outDecimals = IERC20Meta(outToken).decimals();
        uint8 inDecimals = IERC20Meta(inToken).decimals();

        if (inDecimals == outDecimals) {
            return value;
        }

        if (inDecimals > outDecimals) {
            uint256 diff = inDecimals - outDecimals;
            return value / (10 ** diff);
        } else {
            uint256 diff = outDecimals - inDecimals;
            return value * (10 ** diff);
        }
    }

    // EIP165 support
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0xdbb21d40; // TokenQuote
    }
}
