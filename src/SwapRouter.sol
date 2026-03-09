// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {SwapPool} from "./SwapPool.sol";

/// @notice Stateless quoter for multi-hop swap routes.
/// Computes input/output amounts across multiple SwapPools — does not execute swaps.
contract SwapRouter {
    error EmptyPath();

    struct Hop {
        address pool;
        address tokenIn;
        address tokenOut;
    }

    /// @notice Given an input amount, compute the final output after all hops
    function quoteExactInput(Hop[] calldata path, uint256 amountIn) external returns (uint256 amountOut) {
        if (path.length == 0) revert EmptyPath();

        amountOut = amountIn;
        for (uint256 i = 0; i < path.length; i++) {
            amountOut = SwapPool(path[i].pool).getAmountOut(path[i].tokenOut, path[i].tokenIn, amountOut);
        }
    }

    /// @notice Given a desired output amount, compute the required input across all hops
    function quoteExactOutput(Hop[] calldata path, uint256 amountOut) external returns (uint256 amountIn) {
        if (path.length == 0) revert EmptyPath();

        amountIn = amountOut;
        for (uint256 i = path.length; i > 0; i--) {
            amountIn = SwapPool(path[i - 1].pool).getAmountIn(path[i - 1].tokenOut, path[i - 1].tokenIn, amountIn);
        }
    }
}
