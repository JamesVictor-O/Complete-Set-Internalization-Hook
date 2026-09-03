// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IWrapped1155Factory} from "../interfaces/IWrapped1155Factory.sol";
import {ICompleteSetInternalizationHook} from "../interfaces/ICompleteSetInternalizationHook.sol";
import {CompleteSetLib} from "./CompleteSetLib.sol";

library CrossPoolExecutionLib {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct Quote {
        uint256 amount;
        bool available;
    }

    function marketId(IERC20 collateral, bytes32 conditionId) internal pure returns (bytes32) {
        return keccak256(abi.encode(collateral, conditionId));
    }

    function quoteExactInput(IPoolManager manager, PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (Quote memory quote)
    {
        if (amountIn == 0) return quote;
        (uint160 sqrtPriceX96,,, uint24 fee) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());
        // This lightweight on-chain quoter deliberately refuses sizes larger than current active
        // liquidity. It does not walk initialized ticks, so treating that liquidity as available
        // across arbitrary ranges would make a thin complementary pool look deeper than it is.
        if (liquidity == 0 || amountIn > liquidity) return quote;
        (, uint256 used, uint256 out, uint256 feeAmount) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            liquidity,
            -int256(amountIn),
            fee
        );
        if (used + feeAmount != amountIn || out == 0) return quote;
        return Quote(out, true);
    }

    function quoteExactOutput(IPoolManager manager, PoolKey memory key, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (Quote memory quote)
    {
        if (amountOut == 0) return quote;
        (uint160 sqrtPriceX96,,, uint24 fee) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());
        if (liquidity == 0 || amountOut > liquidity) return quote;
        (, uint256 input, uint256 output, uint256 feeAmount) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            liquidity,
            int256(amountOut),
            fee
        );
        if (output != amountOut) return quote;
        return Quote(input + feeAmount, true);
    }

    function splitAndExecuteSynthetic(
        IConditionalTokens ctf,
        IWrapped1155Factory factory,
        IPoolManager manager,
        ICompleteSetInternalizationHook.Market storage market,
        bool targetYes,
        uint256 outcomeAmount,
        uint256 minComplementProceeds
    ) internal returns (uint256 complementProceeds) {
        market.freeCollateral -= outcomeAmount;
        ctf.splitPosition(
            market.collateralToken, bytes32(0), market.conditionId, CompleteSetLib.binaryPartition(), outcomeAmount
        );

        uint256 targetId = targetYes ? market.yesPositionId : market.noPositionId;
        uint256 complementId = targetYes ? market.noPositionId : market.yesPositionId;
        bytes memory targetData = targetYes ? market.yesWrapData : market.noWrapData;
        bytes memory complementData = targetYes ? market.noWrapData : market.yesWrapData;
        Currency targetCurrency = targetYes ? market.yesCurrency : market.noCurrency;
        Currency complementCurrency = targetYes ? market.noCurrency : market.yesCurrency;
        PoolKey memory complementKey = targetYes ? market.noPoolKey : market.yesPoolKey;

        ctf.safeTransferFrom(address(this), address(factory), targetId, outcomeAmount, targetData);
        ctf.safeTransferFrom(address(this), address(factory), complementId, outcomeAmount, complementData);

        bool sellZeroForOne = complementKey.currency0 == complementCurrency;
        BalanceDelta delta = manager.swap(
            complementKey,
            SwapParams({
                zeroForOne: sellZeroForOne,
                amountSpecified: -int256(outcomeAmount),
                sqrtPriceLimitX96: sellZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        complementProceeds = uint256(int256(sellZeroForOne ? delta.amount1() : delta.amount0()));
        if (complementProceeds < minComplementProceeds) {
            revert ICompleteSetInternalizationHook.SlippageExceeded(complementProceeds, minComplementProceeds);
        }
        complementCurrency.settle(manager, address(this), outcomeAmount, false);
        market.collateralCurrency.take(manager, address(this), complementProceeds, false);
        market.freeCollateral += complementProceeds;
        targetCurrency.settle(manager, address(this), outcomeAmount, false);
    }

    function wrapPosition(
        IConditionalTokens ctf,
        IWrapped1155Factory factory,
        uint256 positionId,
        bytes memory wrapData,
        uint256 amount
    ) internal {
        ctf.safeTransferFrom(address(this), address(factory), positionId, amount, wrapData);
    }

    function sellExactInput(
        IPoolManager manager,
        PoolKey memory key,
        Currency sellCurrency,
        Currency collateralCurrency,
        uint256 amount,
        uint256 minOut
    ) internal returns (uint256 amountOut) {
        bool zeroForOne = key.currency0 == sellCurrency;
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        amountOut = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
        if (amountOut < minOut) revert ICompleteSetInternalizationHook.SlippageExceeded(amountOut, minOut);
        sellCurrency.settle(manager, address(this), amount, false);
        collateralCurrency.take(manager, address(this), amountOut, false);
    }

    function buyExactOutput(
        IPoolManager manager,
        PoolKey memory key,
        Currency outcomeCurrency,
        Currency collateralCurrency,
        uint256 amountOut,
        uint256 maxCost
    ) internal returns (uint256 cost) {
        bool zeroForOne = key.currency1 == outcomeCurrency;
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        cost = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
        if (cost > maxCost) revert ICompleteSetInternalizationHook.SlippageExceeded(cost, maxCost);
        collateralCurrency.settle(manager, address(this), cost, false);
        outcomeCurrency.take(manager, address(this), amountOut, false);
    }

    function unwrapPosition(
        IConditionalTokens ctf,
        IWrapped1155Factory factory,
        uint256 positionId,
        bytes memory wrapData,
        uint256 amount
    ) internal {
        factory.unwrap(ctf, positionId, amount, address(this), wrapData);
    }
}
