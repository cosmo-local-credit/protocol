// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

interface IFeePolicy {
    function getFee(address tokenIn, address tokenOut) external view returns (uint256);

    function isActive() external view returns (bool);
}
