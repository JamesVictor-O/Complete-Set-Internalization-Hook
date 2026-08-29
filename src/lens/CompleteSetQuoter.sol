// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ICompleteSetInternalizationHook} from "../interfaces/ICompleteSetInternalizationHook.sol";
import {CompleteSetLib} from "../libraries/CompleteSetLib.sol";

/// @title CompleteSetQuoter
/// @notice Read-only lens that answers, for a given trade, the question
/// {CompleteSetInternalizationHook-_beforeSwap} answers internally at execution time: what would the
/// AMM curve alone give versus the CTF complete-set backstop, and which one would the hook actually
/// pick? Exists purely so that comparison is a testable, callable unit on its own (per CLAUDE.md's
/// "Unit tests for quote comparison logic" requirement) and so a frontend can show both quotes before a
/// trader commits to a swap.
/// @dev A separate, standalone contract — deliberately not part of the hook or `CompleteSetLib` — so it
/// carries none of their EIP-170 size pressure. `quote`'s `recommendCtf` calls
/// `CompleteSetLib.priceIsAtOrPastParity` directly, the exact same deployed library call
/// `_beforeSwap` itself makes, so this contract's recommendation can never drift from what the hook
/// actually does for the same inputs.
contract CompleteSetQuoter {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice One side of a quote comparison.
    /// @param outAmount Amount of the receive currency this path would yield.
    /// @param effectivePriceWad `amountIn * 1e18 / outAmount` — both legs are nominally $1-pegged
    /// (each is a CTF split of collateral), so this reads directly as "$ paid per unit received".
    /// @param priceImpactBps Absolute deviation of `effectivePriceWad` from the fair 1e18 ($1.00), in
    /// basis points.
    /// @param available Whether this path can actually fill the trade at all (false for the AMM leg
    /// with zero core liquidity, or the CTF leg when the hook's reserve can't cover `amountIn`).
    struct SwapQuote {
        uint256 outAmount;
        uint256 effectivePriceWad;
        uint256 priceImpactBps;
        bool available;
    }

    /// @param recommendCtf True exactly when {CompleteSetInternalizationHook-_beforeSwap} would route
    /// this trade through the CTF backstop instead of the AMM curve.
    struct QuoteResult {
        SwapQuote ammQuote;
        SwapQuote ctfQuote;
        bool recommendCtf;
    }

    uint256 internal constant WAD = 1e18;

    IPoolManager public immutable poolManager;
    ICompleteSetInternalizationHook public immutable hook;

    constructor(IPoolManager _poolManager, ICompleteSetInternalizationHook _hook) {
        poolManager = _poolManager;
        hook = _hook;
    }

    /// @notice Quotes both paths for an exact-input trade of `amountIn` of the currency `zeroForOne`
    /// implies (paying currency0 if true, currency1 if false).
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (QuoteResult memory result)
    {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        result.ammQuote = _quoteAmm(sqrtPriceX96, liquidity, zeroForOne, amountIn, lpFee);

        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        result.ctfQuote = _quoteCtf(amountIn, market.collateralReserve);

        result.recommendCtf = result.ctfQuote.available
            && CompleteSetLib.priceIsAtOrPastParity(poolManager, poolId, zeroForOne, amountIn, true);
    }

    /// @dev Single-active-tick approximation (does not simulate crossing into the next initialized
    /// tick) — the same deliberate MVP simplification `CompleteSetLib.priceIsAtOrPastParity` already
    /// uses for its own trade-impact projection, kept consistent here.
    function _quoteAmm(uint160 sqrtPriceX96, uint128 liquidity, bool zeroForOne, uint256 amountIn, uint24 lpFee)
        internal
        pure
        returns (SwapQuote memory swapQuote)
    {
        if (liquidity == 0 || amountIn == 0) return swapQuote;

        uint160 sqrtPriceTargetX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (, uint256 stepAmountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceTargetX96, liquidity, -int256(amountIn), lpFee);

        // If the single active tick's liquidity can't absorb the full amountIn before hitting the price
        // bound, this quote is only a partial fill — flag it as unavailable rather than silently
        // understating amountIn.
        if (stepAmountIn + feeAmount < amountIn || amountOut == 0) return swapQuote;

        swapQuote = _buildQuote(amountIn, amountOut, true);
    }

    function _quoteCtf(uint256 amountIn, uint256 collateralReserve) internal pure returns (SwapQuote memory) {
        if (amountIn == 0 || collateralReserve < amountIn) return SwapQuote(0, 0, 0, false);
        // The CTF path is always exactly 1:1, never partial - see CompleteSetLib.fillFromCompleteSet.
        return SwapQuote(amountIn, WAD, 0, true);
    }

    function _buildQuote(uint256 amountIn, uint256 outAmount, bool available)
        internal
        pure
        returns (SwapQuote memory)
    {
        uint256 effectivePriceWad = (amountIn * WAD) / outAmount;
        uint256 priceImpactBps = effectivePriceWad >= WAD
            ? ((effectivePriceWad - WAD) * 10_000) / WAD
            : ((WAD - effectivePriceWad) * 10_000) / WAD;
        return SwapQuote(outAmount, effectivePriceWad, priceImpactBps, available);
    }
}
