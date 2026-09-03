// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ICompleteSetInternalizationHook} from "../interfaces/ICompleteSetInternalizationHook.sol";
import {CrossPoolExecutionLib} from "../libraries/CrossPoolExecutionLib.sol";

contract CompleteSetQuoter {
    using PoolIdLibrary for PoolKey;

    struct ExecutionQuote {
        uint256 amount;
        uint256 complementProceeds;
        uint256 reserveRequired;
        bool available;
    }

    struct QuoteResult {
        ExecutionQuote ammQuote;
        ExecutionQuote syntheticQuote;
        bool recommendSynthetic;
    }

    uint256 private constant BPS = 10_000;
    IPoolManager public immutable poolManager;
    ICompleteSetInternalizationHook public immutable hook;

    constructor(IPoolManager manager, ICompleteSetInternalizationHook hook_) {
        poolManager = manager;
        hook = hook_;
    }

    function quote(PoolKey calldata targetKey, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (QuoteResult memory result)
    {
        ICompleteSetInternalizationHook.PoolBinding memory binding = hook.poolBinding(targetKey.toId());
        if (!binding.registered) return result;
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(binding.marketId);
        if (market.frozen) return result;
        Currency pay = zeroForOne ? targetKey.currency0 : targetKey.currency1;
        Currency receiveCurrency = zeroForOne ? targetKey.currency1 : targetKey.currency0;
        Currency target = binding.isYes ? market.yesCurrency : market.noCurrency;
        if (!(pay == market.collateralCurrency) || !(receiveCurrency == target)) return result;

        CrossPoolExecutionLib.Quote memory amm =
            CrossPoolExecutionLib.quoteExactInput(poolManager, targetKey, zeroForOne, amountIn);
        result.ammQuote = ExecutionQuote(amm.amount, 0, 0, amm.available);

        PoolKey memory complementKey = binding.isYes ? market.noPoolKey : market.yesPoolKey;
        Currency complement = binding.isYes ? market.noCurrency : market.yesCurrency;
        bool complementZeroForOne = complementKey.currency0 == complement;
        CrossPoolExecutionLib.Quote memory sale =
            CrossPoolExecutionLib.quoteExactInput(poolManager, complementKey, complementZeroForOne, amountIn);
        if (!sale.available || sale.amount >= amountIn || market.freeCollateral < amountIn) return result;
        CrossPoolExecutionLib.Quote memory recycled =
            CrossPoolExecutionLib.quoteExactInput(poolManager, targetKey, zeroForOne, sale.amount);
        if (!recycled.available) return result;

        uint256 syntheticOut = amountIn + recycled.amount;
        result.syntheticQuote = ExecutionQuote(syntheticOut, sale.amount, amountIn, true);
        result.recommendSynthetic = amm.available && syntheticOut * BPS >= amm.amount * (BPS + hook.SAFETY_MARGIN_BPS());
    }

    function quoteExactOutput(PoolKey calldata targetKey, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (QuoteResult memory result)
    {
        ICompleteSetInternalizationHook.PoolBinding memory binding = hook.poolBinding(targetKey.toId());
        if (!binding.registered) return result;
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(binding.marketId);
        if (market.frozen) return result;
        Currency pay = zeroForOne ? targetKey.currency0 : targetKey.currency1;
        if (!(pay == market.collateralCurrency)) return result;

        CrossPoolExecutionLib.Quote memory amm =
            CrossPoolExecutionLib.quoteExactOutput(poolManager, targetKey, zeroForOne, amountOut);
        result.ammQuote = ExecutionQuote(amm.amount, 0, 0, amm.available);
        PoolKey memory complementKey = binding.isYes ? market.noPoolKey : market.yesPoolKey;
        Currency complement = binding.isYes ? market.noCurrency : market.yesCurrency;
        CrossPoolExecutionLib.Quote memory sale = CrossPoolExecutionLib.quoteExactInput(
            poolManager, complementKey, complementKey.currency0 == complement, amountOut
        );
        if (!sale.available || sale.amount >= amountOut || market.freeCollateral < amountOut) return result;
        uint256 syntheticCost = amountOut - sale.amount;
        result.syntheticQuote = ExecutionQuote(syntheticCost, sale.amount, amountOut, true);
        result.recommendSynthetic =
            amm.available && syntheticCost * (BPS + hook.SAFETY_MARGIN_BPS()) <= amm.amount * BPS;
    }
}
