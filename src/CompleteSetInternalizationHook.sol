// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "openzeppelin/token/ERC1155/utils/ERC1155Holder.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {IWrapped1155Factory} from "./interfaces/IWrapped1155Factory.sol";
import {ICompleteSetInternalizationHook} from "./interfaces/ICompleteSetInternalizationHook.sol";
import {CompleteSetLib} from "./libraries/CompleteSetLib.sol";
import {CrossPoolExecutionLib} from "./libraries/CrossPoolExecutionLib.sol";

contract CompleteSetInternalizationHook is BaseHook, ERC1155Holder, IUnlockCallback, ICompleteSetInternalizationHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant SAFETY_MARGIN_BPS = 30;
    uint256 private constant BPS = 10_000;

    IConditionalTokens public immutable conditionalTokens;
    IWrapped1155Factory public immutable wrapped1155Factory;

    mapping(bytes32 => Market) private _markets;
    mapping(PoolId => PoolBinding) private _poolBindings;
    mapping(bytes32 => mapping(address => uint256)) public sharesOf;

    constructor(IPoolManager manager, IConditionalTokens ctf, IWrapped1155Factory factory) BaseHook(manager) {
        conditionalTokens = ctf;
        wrapped1155Factory = factory;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function registerMarket(
        PoolKey calldata yesPoolKey,
        PoolKey calldata noPoolKey,
        IERC20 collateralToken,
        bytes32 conditionId,
        string calldata,
        string calldata,
        string calldata,
        string calldata
    ) external returns (bytes32 id) {
        if (conditionalTokens.getOutcomeSlotCount(conditionId) != 2) {
            revert ConditionNotBinary(conditionId, conditionalTokens.getOutcomeSlotCount(conditionId));
        }
        if (conditionalTokens.payoutDenominator(conditionId) != 0) revert ConditionAlreadyResolved(conditionId);

        id = CrossPoolExecutionLib.marketId(collateralToken, conditionId);
        if (_markets[id].registered) revert MarketAlreadyRegistered(id);

        uint256 yesPositionId = CompleteSetLib.yesPositionId(collateralToken, conditionId);
        uint256 noPositionId = CompleteSetLib.noPositionId(collateralToken, conditionId);
        Currency yes = Currency.wrap(wrapped1155Factory.requireWrapped1155(conditionalTokens, yesPositionId));
        Currency no = Currency.wrap(wrapped1155Factory.requireWrapped1155(conditionalTokens, noPositionId));
        Currency collateral = Currency.wrap(address(collateralToken));

        _validatePool(yesPoolKey, collateral, yes);
        _validatePool(noPoolKey, collateral, no);
        PoolId yesPoolId = yesPoolKey.toId();
        PoolId noPoolId = noPoolKey.toId();
        if (_poolBindings[yesPoolId].registered) revert PoolAlreadyBound(yesPoolId);
        if (_poolBindings[noPoolId].registered) revert PoolAlreadyBound(noPoolId);
        if (PoolId.unwrap(yesPoolId) == PoolId.unwrap(noPoolId)) revert InvalidOutcomePool(yesPoolId);

        Market storage market = _markets[id];
        market.registered = true;
        market.collateralToken = collateralToken;
        market.collateralCurrency = collateral;
        market.conditionId = conditionId;
        market.yesCurrency = yes;
        market.noCurrency = no;
        market.yesPoolKey = yesPoolKey;
        market.noPoolKey = noPoolKey;
        market.yesPoolId = yesPoolId;
        market.noPoolId = noPoolId;
        market.yesPositionId = yesPositionId;
        market.noPositionId = noPositionId;
        market.yesWrapData = CompleteSetLib.encodeWrappedTokenData(address(this));
        market.noWrapData = CompleteSetLib.encodeWrappedTokenData(address(this));
        _poolBindings[yesPoolId] = PoolBinding(true, true, id);
        _poolBindings[noPoolId] = PoolBinding(true, false, id);
        collateralToken.forceApprove(address(conditionalTokens), type(uint256).max);

        emit MarketRegistered(
            id, conditionId, yesPoolId, noPoolId, address(collateralToken), Currency.unwrap(yes), Currency.unwrap(no)
        );
    }

    function _validatePool(PoolKey calldata key, Currency collateral, Currency outcome) private view {
        bool pair = (key.currency0 == collateral && key.currency1 == outcome)
            || (key.currency1 == collateral && key.currency0 == outcome);
        if (!pair || address(key.hooks) != address(this)) revert InvalidOutcomePool(key.toId());
    }

    function depositCollateral(bytes32 marketId, uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        Market storage market = _market(marketId);
        if (market.pendingCollateralClaims != 0) revert PendingSettlement();
        market.collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        sharesMinted = market.totalShares == 0 ? amount : amount * market.totalShares / market.freeCollateral;
        market.freeCollateral += amount;
        market.totalShares += sharesMinted;
        sharesOf[marketId][msg.sender] += sharesMinted;
        emit CollateralDeposited(marketId, msg.sender, amount, sharesMinted);
    }

    function withdrawCollateral(bytes32 marketId, uint256 shares) external returns (uint256 amountOut) {
        if (shares == 0) revert ZeroAmount();
        Market storage market = _market(marketId);
        if (market.pendingCollateralClaims != 0 || market.yesInventory != 0 || market.noInventory != 0) {
            revert PendingSettlement();
        }
        uint256 available = sharesOf[marketId][msg.sender];
        if (shares > available) revert InsufficientShares(shares, available);
        amountOut = shares * market.freeCollateral / market.totalShares;
        sharesOf[marketId][msg.sender] = available - shares;
        market.totalShares -= shares;
        market.freeCollateral -= amountOut;
        market.collateralToken.safeTransfer(msg.sender, amountOut);
        emit CollateralWithdrawn(marketId, msg.sender, amountOut, shares);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId targetPoolId = key.toId();
        PoolBinding memory binding = _poolBindings[targetPoolId];
        if (!binding.registered) revert MarketNotRegistered(bytes32(PoolId.unwrap(targetPoolId)));
        Market storage market = _markets[binding.marketId];
        if (market.frozen) return _noRoute();

        bool exactInput = params.amountSpecified < 0;
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        Currency pay = params.zeroForOne ? key.currency0 : key.currency1;
        Currency receiveCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency target = binding.isYes ? market.yesCurrency : market.noCurrency;
        if (exactInput) {
            if (!(pay == market.collateralCurrency) || !(receiveCurrency == target)) return _noRoute();
            (bool useSynthetic,, uint256 complementProceeds) =
                _quoteExactInput(market, binding.isYes, amount, params.zeroForOne);
            if (!useSynthetic || market.freeCollateral < amount) return _noRoute();
            uint256 realized = CrossPoolExecutionLib.splitAndExecuteSynthetic(
                conditionalTokens, wrapped1155Factory, poolManager, market, binding.isYes, amount, complementProceeds
            );
            uint256 netCost = amount - realized;
            market.collateralCurrency.take(poolManager, address(this), netCost, true);
            market.pendingCollateralClaims += netCost;
            emit SyntheticFill(binding.marketId, targetPoolId, sender, true, amount, realized, netCost);
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(netCost.toInt128(), -amount.toInt128()), 0);
        }

        if (!(pay == market.collateralCurrency) || !(receiveCurrency == target)) return _noRoute();
        (bool useSyntheticOutput,, uint256 outputComplementProceeds) =
            _quoteExactOutput(market, binding.isYes, amount, params.zeroForOne);
        if (!useSyntheticOutput || market.freeCollateral < amount) return _noRoute();
        uint256 outputRealized = CrossPoolExecutionLib.splitAndExecuteSynthetic(
            conditionalTokens, wrapped1155Factory, poolManager, market, binding.isYes, amount, outputComplementProceeds
        );
        uint256 outputNetCost = amount - outputRealized;
        market.collateralCurrency.take(poolManager, address(this), outputNetCost, true);
        market.pendingCollateralClaims += outputNetCost;
        emit SyntheticFill(binding.marketId, targetPoolId, sender, false, amount, outputRealized, outputNetCost);
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(-amount.toInt128(), outputNetCost.toInt128()), 0);
    }

    function _quoteExactInput(Market storage market, bool targetYes, uint256 amount, bool targetZeroForOne)
        private
        view
        returns (bool useSynthetic, uint256 ammOut, uint256 complementProceeds)
    {
        PoolKey memory targetKey = targetYes ? market.yesPoolKey : market.noPoolKey;
        PoolKey memory complementKey = targetYes ? market.noPoolKey : market.yesPoolKey;
        Currency complement = targetYes ? market.noCurrency : market.yesCurrency;
        CrossPoolExecutionLib.Quote memory amm =
            CrossPoolExecutionLib.quoteExactInput(poolManager, targetKey, targetZeroForOne, amount);
        bool complementZeroForOne = complementKey.currency0 == complement;
        CrossPoolExecutionLib.Quote memory sale =
            CrossPoolExecutionLib.quoteExactInput(poolManager, complementKey, complementZeroForOne, amount);
        if (!amm.available || !sale.available || sale.amount >= amount) return (false, amm.amount, sale.amount);
        CrossPoolExecutionLib.Quote memory recycled =
            CrossPoolExecutionLib.quoteExactInput(poolManager, targetKey, targetZeroForOne, sale.amount);
        if (!recycled.available) return (false, amm.amount, sale.amount);
        uint256 syntheticOut = amount + recycled.amount;
        useSynthetic = syntheticOut * BPS >= amm.amount * (BPS + SAFETY_MARGIN_BPS);
        return (useSynthetic, amm.amount, sale.amount);
    }

    function _quoteExactOutput(Market storage market, bool targetYes, uint256 amount, bool targetZeroForOne)
        private
        view
        returns (bool useSynthetic, uint256 ammCost, uint256 complementProceeds)
    {
        PoolKey memory targetKey = targetYes ? market.yesPoolKey : market.noPoolKey;
        PoolKey memory complementKey = targetYes ? market.noPoolKey : market.yesPoolKey;
        Currency complement = targetYes ? market.noCurrency : market.yesCurrency;
        CrossPoolExecutionLib.Quote memory amm =
            CrossPoolExecutionLib.quoteExactOutput(poolManager, targetKey, targetZeroForOne, amount);
        bool complementZeroForOne = complementKey.currency0 == complement;
        CrossPoolExecutionLib.Quote memory sale =
            CrossPoolExecutionLib.quoteExactInput(poolManager, complementKey, complementZeroForOne, amount);
        if (!amm.available || !sale.available || sale.amount >= amount) return (false, amm.amount, sale.amount);
        uint256 syntheticCost = amount - sale.amount;
        useSynthetic = syntheticCost * (BPS + SAFETY_MARGIN_BPS) <= amm.amount * BPS;
        return (useSynthetic, amm.amount, sale.amount);
    }

    function _noRoute() private pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    enum UnlockAction {
        Sweep,
        SplitArbitrage,
        MergeArbitrage
    }

    function sweepCollateralClaims(bytes32 marketId) external returns (uint256 amountSwept) {
        _market(marketId);
        amountSwept = abi.decode(poolManager.unlock(abi.encode(UnlockAction.Sweep, abi.encode(marketId))), (uint256));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (UnlockAction action, bytes memory payload) = abi.decode(data, (UnlockAction, bytes));
        if (action == UnlockAction.SplitArbitrage) {
            (bytes32 id, uint256 arbAmount, uint256 yesMin, uint256 noMin, uint256 required) =
                abi.decode(payload, (bytes32, uint256, uint256, uint256, uint256));
            return abi.encode(_executeSplit(id, arbAmount, yesMin, noMin, required));
        }
        if (action == UnlockAction.MergeArbitrage) {
            (bytes32 id, uint256 arbAmount, uint256 yesMax, uint256 noMax, uint256 required) =
                abi.decode(payload, (bytes32, uint256, uint256, uint256, uint256));
            return abi.encode(_executeMerge(id, arbAmount, yesMax, noMax, required));
        }
        bytes32 marketId = abi.decode(payload, (bytes32));
        Market storage market = _market(marketId);
        uint256 amount = market.pendingCollateralClaims;
        if (amount != 0) {
            market.collateralCurrency.settle(poolManager, address(this), amount, true);
            market.collateralCurrency.take(poolManager, address(this), amount, false);
            market.pendingCollateralClaims = 0;
            market.freeCollateral += amount;
            emit CollateralClaimsSwept(marketId, amount);
        }
        return abi.encode(amount);
    }

    function executeSplitArbitrage(bytes32 marketId, uint256 amount, uint256 minSurplus)
        external
        returns (uint256 surplus)
    {
        if (amount == 0) revert ZeroAmount();
        Market storage market = _market(marketId);
        if (market.frozen) revert MarketFrozenError(marketId);
        if (market.pendingCollateralClaims != 0) revert PendingSettlement();
        if (market.freeCollateral < amount) revert InsufficientFreeCollateral(amount, market.freeCollateral);
        CrossPoolExecutionLib.Quote memory yesQuote = CrossPoolExecutionLib.quoteExactInput(
            poolManager, market.yesPoolKey, market.yesPoolKey.currency0 == market.yesCurrency, amount
        );
        CrossPoolExecutionLib.Quote memory noQuote = CrossPoolExecutionLib.quoteExactInput(
            poolManager, market.noPoolKey, market.noPoolKey.currency0 == market.noCurrency, amount
        );
        uint256 required = _requiredSurplus(amount, minSurplus);
        if (!yesQuote.available || !noQuote.available || yesQuote.amount + noQuote.amount < amount + required) {
            revert InsufficientEdge(yesQuote.amount + noQuote.amount, amount + required);
        }
        surplus = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockAction.SplitArbitrage, abi.encode(marketId, amount, yesQuote.amount, noQuote.amount, required)
                )
            ),
            (uint256)
        );
    }

    function executeMergeArbitrage(bytes32 marketId, uint256 amount, uint256 maxCost, uint256 minSurplus)
        external
        returns (uint256 surplus)
    {
        if (amount == 0) revert ZeroAmount();
        Market storage market = _market(marketId);
        if (market.frozen) revert MarketFrozenError(marketId);
        if (market.pendingCollateralClaims != 0) revert PendingSettlement();
        bool yesZeroForOne = market.yesPoolKey.currency0 == market.collateralCurrency;
        bool noZeroForOne = market.noPoolKey.currency0 == market.collateralCurrency;
        CrossPoolExecutionLib.Quote memory yesQuote =
            CrossPoolExecutionLib.quoteExactOutput(poolManager, market.yesPoolKey, yesZeroForOne, amount);
        CrossPoolExecutionLib.Quote memory noQuote =
            CrossPoolExecutionLib.quoteExactOutput(poolManager, market.noPoolKey, noZeroForOne, amount);
        uint256 totalCost = yesQuote.amount + noQuote.amount;
        uint256 required = _requiredSurplus(amount, minSurplus);
        if (
            !yesQuote.available || !noQuote.available || totalCost > maxCost || totalCost + required > amount
                || market.freeCollateral < totalCost
        ) revert InsufficientEdge(amount, totalCost + required);
        surplus = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockAction.MergeArbitrage, abi.encode(marketId, amount, yesQuote.amount, noQuote.amount, required)
                )
            ),
            (uint256)
        );
    }

    function _executeSplit(bytes32 marketId, uint256 amount, uint256 yesMin, uint256 noMin, uint256 required)
        private
        returns (uint256 surplus)
    {
        Market storage market = _markets[marketId];
        market.freeCollateral -= amount;
        conditionalTokens.splitPosition(
            market.collateralToken, bytes32(0), market.conditionId, CompleteSetLib.binaryPartition(), amount
        );
        CrossPoolExecutionLib.wrapPosition(
            conditionalTokens, wrapped1155Factory, market.yesPositionId, market.yesWrapData, amount
        );
        CrossPoolExecutionLib.wrapPosition(
            conditionalTokens, wrapped1155Factory, market.noPositionId, market.noWrapData, amount
        );
        uint256 yesProceeds = CrossPoolExecutionLib.sellExactInput(
            poolManager, market.yesPoolKey, market.yesCurrency, market.collateralCurrency, amount, yesMin
        );
        uint256 noProceeds = CrossPoolExecutionLib.sellExactInput(
            poolManager, market.noPoolKey, market.noCurrency, market.collateralCurrency, amount, noMin
        );
        uint256 proceeds = yesProceeds + noProceeds;
        surplus = proceeds - amount;
        if (surplus < required) revert InsufficientEdge(surplus, required);
        market.freeCollateral += proceeds;
        market.lifetimeSurplus += surplus;
        emit SplitArbitrage(marketId, amount, proceeds, surplus);
    }

    function _executeMerge(bytes32 marketId, uint256 amount, uint256 yesMax, uint256 noMax, uint256 required)
        private
        returns (uint256 surplus)
    {
        Market storage market = _markets[marketId];
        uint256 yesCost = CrossPoolExecutionLib.buyExactOutput(
            poolManager, market.yesPoolKey, market.yesCurrency, market.collateralCurrency, amount, yesMax
        );
        uint256 noCost = CrossPoolExecutionLib.buyExactOutput(
            poolManager, market.noPoolKey, market.noCurrency, market.collateralCurrency, amount, noMax
        );
        uint256 cost = yesCost + noCost;
        CrossPoolExecutionLib.unwrapPosition(
            conditionalTokens, wrapped1155Factory, market.yesPositionId, market.yesWrapData, amount
        );
        CrossPoolExecutionLib.unwrapPosition(
            conditionalTokens, wrapped1155Factory, market.noPositionId, market.noWrapData, amount
        );
        uint256 beforeBalance = market.collateralToken.balanceOf(address(this));
        conditionalTokens.mergePositions(
            market.collateralToken, bytes32(0), market.conditionId, CompleteSetLib.binaryPartition(), amount
        );
        uint256 recovered = market.collateralToken.balanceOf(address(this)) - beforeBalance;
        surplus = recovered - cost;
        if (surplus < required) revert InsufficientEdge(surplus, required);
        market.freeCollateral = market.freeCollateral - cost + recovered;
        market.lifetimeSurplus += surplus;
        emit MergeArbitrage(marketId, amount, cost, surplus);
    }

    function _requiredSurplus(uint256 amount, uint256 callerMinimum) private pure returns (uint256) {
        uint256 protocolMinimum = amount * SAFETY_MARGIN_BPS / BPS;
        return callerMinimum > protocolMinimum ? callerMinimum : protocolMinimum;
    }

    function freezeForResolution(bytes32 marketId) external {
        Market storage market = _market(marketId);
        if (conditionalTokens.payoutDenominator(market.conditionId) == 0) {
            revert ConditionNotYetResolved(market.conditionId);
        }
        market.frozen = true;
        emit MarketFrozen(marketId);
    }

    function redeemAfterResolution(bytes32 marketId) external returns (uint256 collateralReceived) {
        Market storage market = _market(marketId);
        if (!market.frozen) revert MarketFrozenError(marketId);
        uint256 beforeBalance = market.collateralToken.balanceOf(address(this));
        conditionalTokens.redeemPositions(
            market.collateralToken, bytes32(0), market.conditionId, CompleteSetLib.binaryPartition()
        );
        collateralReceived = market.collateralToken.balanceOf(address(this)) - beforeBalance;
        market.yesInventory = 0;
        market.noInventory = 0;
        market.freeCollateral += collateralReceived;
        emit MarketRedeemed(marketId, collateralReceived);
    }

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    function getMarketForPool(PoolId poolId) external view returns (Market memory market, PoolBinding memory binding) {
        binding = _poolBindings[poolId];
        market = _markets[binding.marketId];
    }

    function poolBinding(PoolId poolId) external view returns (PoolBinding memory) {
        return _poolBindings[poolId];
    }

    function _market(bytes32 marketId) private view returns (Market storage market) {
        market = _markets[marketId];
        if (!market.registered) revert MarketNotRegistered(marketId);
    }
}
