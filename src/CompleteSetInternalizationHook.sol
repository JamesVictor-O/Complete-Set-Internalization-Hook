// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "openzeppelin/token/ERC1155/utils/ERC1155Holder.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {IWrapped1155Factory} from "./interfaces/IWrapped1155Factory.sol";
import {ICompleteSetInternalizationHook} from "./interfaces/ICompleteSetInternalizationHook.sol";
import {CompleteSetLib} from "./libraries/CompleteSetLib.sol";

/// @title CompleteSetInternalizationHook
/// @notice Uniswap v4 hook that uses the Gnosis Conditional Tokens Framework (CTF) complete-set
/// invariant (1 YES + 1 NO == 1 collateral) as a structural, ~1:1 backstop for a YES/NO pool.
///
/// INVARIANTS THIS CONTRACT MUST NEVER BREAK (see CLAUDE.md):
///   1. `yesInventory` and `noInventory` (in complete sets) can always be merged 1:1 back to collateral.
///   2. When the CTF path is taken, the `PoolManager`'s own delta for the swap is exactly zero — the
///      hook fully take()s the input and settle()s the output itself.
///   3. No user funds can be stuck or silently lost.
///   4. Surplus only ever comes from a real `mergePositions` call whose 1:1 payout exceeds the tracked
///      acquisition cost of what was merged — never credited out of thin air.
///
/// A NOTE ON WHY THE TRADER'S PAYMENT IS TAKEN AS A CLAIM, NOT REAL TOKENS:
/// `beforeSwap` runs before the swap's router has settled anything — the router only pulls the
/// trader's real tokens into the `PoolManager` *after* `swap()` returns, and `beforeSwap` runs strictly
/// before that. So a hook can never hold the trader's input as real ERC-20 mid-swap; the only real
/// tokens available inside `beforeSwap` are ones the hook (or the pool) already possessed beforehand.
/// This hook still fully NoOps the swap (Invariant #2): the *output* leg is settled for real, funded
/// from the hook's own pre-existing collateral reserve via a fresh CTF split, and the *input* leg is
/// taken as an ERC-6909 claim (`take(..., claims: true)`), which is exactly as good as real tokens for
/// `PoolManager`'s own zero-delta accounting. That claim is only converted into real, CTF-usable
/// inventory later, via {sweepClaims} — which needs its own `PoolManager.unlock` and so cannot run
/// inside the same `beforeSwap` call (`PoolManager` does not support nested/re-entrant unlocks).
///
/// MECHANISM IMPLEMENTED (defensive backstop, "mechanism A"):
/// A pool trading YES against NO has no inherent reason to stay near 1:1 parity — nothing but the AMM
/// curve's own liquidity resists one side being bid up arbitrarily. This hook fixes that: whenever the
/// pool's current spot price is already at or past 1:1 parity in the direction a trade is pushing it,
/// the hook fills the trade itself via a fresh CTF split (funded from its own collateral reserve) at
/// exactly 1:1, instead of letting the AMM curve execute at a worse price. This structurally caps how
/// far a single trade can move YES/NO pricing away from parity, bounding price impact the same way a
/// $1 collateral redemption right always does for a single outcome token.
///
/// MECHANISM DELIBERATELY NOT IMPLEMENTED HERE ("mechanism B", surplus generation):
/// Because mechanism A fills at exactly 1:1 with no fee, it is capital-neutral to the hook by
/// construction (every collateral unit spent on a split is recovered by the matching merge) — it
/// protects traders from bad pricing, but does not by itself generate LP surplus. Real surplus (Key
/// Invariant #4) requires *opportunistically acquiring* YES and NO for a combined cost below 1
/// collateral (e.g. buying a temporarily underpriced leg off the AMM curve) and then merging the pair.
/// That acquisition strategy needs its own design pass (it means the hook trading into its own pool,
/// with the re-entrancy and pricing implications that carries) and is intentionally left as a follow-up
/// — see {mergeIfPossible} and `outstandingSplitCost`, which already account for it correctly whenever
/// it is added: any merge that recovers more collateral than was spent acquiring the merged units is
/// booked as surplus straight into the LP-shared reserve.
/// @dev Inherits `ERC1155Holder` because both `ConditionalTokens.splitPosition` (minting) and
/// `Wrapped1155Factory.unwrap` (transferring) deliver raw CTF positions to this contract via
/// `safeTransferFrom`/`_mint`, which call `onERC1155Received`/`onERC1155BatchReceived` on the recipient.
contract CompleteSetInternalizationHook is BaseHook, ERC1155Holder, IUnlockCallback, ICompleteSetInternalizationHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using CompleteSetLib for IERC20;

    IConditionalTokens public immutable conditionalTokens;
    IWrapped1155Factory public immutable wrapped1155Factory;

    mapping(PoolId => Market) internal _markets;
    mapping(PoolId => mapping(address => uint256)) public sharesOf;

    constructor(IPoolManager _poolManager, IConditionalTokens _conditionalTokens, IWrapped1155Factory _wrapped1155Factory)
        BaseHook(_poolManager)
    {
        conditionalTokens = _conditionalTokens;
        wrapped1155Factory = _wrapped1155Factory;
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

    // ---------------------------------------------------------------------
    // Market registration
    // ---------------------------------------------------------------------

    /// @inheritdoc ICompleteSetInternalizationHook
    function registerMarket(
        PoolKey calldata key,
        IERC20 collateralToken,
        bytes32 conditionId,
        string calldata yesName,
        string calldata yesSymbol,
        string calldata noName,
        string calldata noSymbol
    ) external {
        PoolId poolId = key.toId();
        Market storage market = _markets[poolId];
        if (market.registered) revert MarketAlreadyRegistered(poolId);
        _requirePreparedUnresolvedBinaryCondition(conditionId);

        market.collateralToken = collateralToken;
        market.conditionId = conditionId;
        market.yesPositionId = collateralToken.yesPositionId(conditionId);
        market.noPositionId = collateralToken.noPositionId(conditionId);
        market.yesWrapData = CompleteSetLib.encodeWrappedTokenData(yesName, yesSymbol, 18);
        market.noWrapData = CompleteSetLib.encodeWrappedTokenData(noName, noSymbol, 18);

        market.yesCurrency = Currency.wrap(
            wrapped1155Factory.requireWrapped1155(conditionalTokens, market.yesPositionId, market.yesWrapData)
        );
        market.noCurrency = Currency.wrap(
            wrapped1155Factory.requireWrapped1155(conditionalTokens, market.noPositionId, market.noWrapData)
        );
        _requireMatchesPoolCurrencies(key, market.yesCurrency, market.noCurrency);
        market.registered = true;

        // One-time max approval so `splitPosition` can pull collateral from this contract.
        // NOTE: not compatible with tokens that require resetting the allowance to zero before it can
        // be changed again (e.g. legacy USDT) — acceptable for the MVP, flagged for production hardening.
        collateralToken.forceApprove(address(conditionalTokens), type(uint256).max);

        emit MarketRegistered(
            poolId, conditionId, address(collateralToken), Currency.unwrap(market.yesCurrency), Currency.unwrap(market.noCurrency)
        );
    }

    function _requirePreparedUnresolvedBinaryCondition(bytes32 conditionId) private view {
        uint256 outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionId);
        if (outcomeSlotCount != CompleteSetLib.BINARY_OUTCOME_SLOT_COUNT) {
            revert ConditionNotBinary(conditionId, outcomeSlotCount);
        }
        if (conditionalTokens.payoutDenominator(conditionId) != 0) revert ConditionAlreadyResolved(conditionId);
    }

    function _requireMatchesPoolCurrencies(PoolKey calldata key, Currency yesCurrency, Currency noCurrency)
        private
        pure
    {
        bool matchesForward = key.currency0 == yesCurrency && key.currency1 == noCurrency;
        bool matchesReverse = key.currency0 == noCurrency && key.currency1 == yesCurrency;
        if (!matchesForward && !matchesReverse) {
            revert CurrencyMismatch(yesCurrency, key.currency0);
        }
    }

    // ---------------------------------------------------------------------
    // LP collateral reserve (NAV = collateralReserve; shares are minted/burned pro-rata against it)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICompleteSetInternalizationHook
    function depositCollateral(PoolKey calldata key, uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        PoolId poolId = key.toId();
        Market storage market = _getRegisteredMarket(poolId);

        market.collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        sharesMinted = market.totalShares == 0 ? amount : (amount * market.totalShares) / market.collateralReserve;
        market.totalShares += sharesMinted;
        market.collateralReserve += amount;
        sharesOf[poolId][msg.sender] += sharesMinted;

        emit CollateralDeposited(poolId, msg.sender, amount, sharesMinted);
    }

    /// @inheritdoc ICompleteSetInternalizationHook
    function withdrawCollateral(PoolKey calldata key, uint256 shares) external returns (uint256 amountOut) {
        if (shares == 0) revert ZeroAmount();
        PoolId poolId = key.toId();
        Market storage market = _getRegisteredMarket(poolId);

        uint256 available = sharesOf[poolId][msg.sender];
        if (shares > available) revert InsufficientShares(shares, available);

        amountOut = (shares * market.collateralReserve) / market.totalShares;

        sharesOf[poolId][msg.sender] = available - shares;
        market.totalShares -= shares;
        market.collateralReserve -= amountOut;

        market.collateralToken.safeTransfer(msg.sender, amountOut);

        emit CollateralWithdrawn(poolId, msg.sender, amountOut, shares);
    }

    // ---------------------------------------------------------------------
    // Swap routing
    // ---------------------------------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Market storage market = _markets[poolId];
        if (!market.registered) revert MarketNotRegistered(poolId);
        if (market.frozen) revert MarketFrozen(poolId);

        // Only a fully NoOp fill is safe to hand back as a pure BeforeSwapDelta here, so a partially
        // filled complete-set trade is never attempted — it is all-AMM or all-CTF for a given swap, for
        // both exact-input and exact-output.
        bool exactInput = params.amountSpecified < 0;
        uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (amount == 0) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        if (!_priceIsAtOrPastParity(poolId, params.zeroForOne, amount, exactInput)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (market.collateralReserve < amount) {
            // Structural backstop unavailable this trade (reserve exhausted) — fall back to the AMM.
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (Currency payCurrency, Currency receiveCurrency) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        CompleteSetLib.fillFromCompleteSet(
            conditionalTokens, wrapped1155Factory, poolManager, market, payCurrency, receiveCurrency, amount
        );

        emit CompleteSetFilled(poolId, sender, params.zeroForOne, amount);

        // Whichever currency the trader *pays* always needs hookDelta = +amount, and whichever they
        // *receive* always needs hookDelta = -amount (see Hooks.sol's beforeSwap/afterSwap accounting) —
        // for exact-input the "specified" currency is the pay leg, for exact-output it's the receive
        // leg, so the two cases are exact negations of each other.
        BeforeSwapDelta returnDelta = exactInput
            ? toBeforeSwapDelta(amount.toInt128(), -amount.toInt128())
            : toBeforeSwapDelta(-amount.toInt128(), amount.toInt128());
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /// @dev Backstop heuristic: routes the full trade through CTF once either (a) the pool's *current*
    /// spot price is already at or past 1:1 parity in the trade's direction, or (b) this trade's own
    /// size, projected against the pool's currently active tick liquidity, would walk the price at or
    /// past parity. (b) is a same-active-tick approximation (it does not simulate crossing into the next
    /// initialized tick) — deliberately simple, and strictly more conservative than (a) alone, since it
    /// only ever routes *more* trades to the safe CTF backstop, never fewer.
    function _priceIsAtOrPastParity(PoolId poolId, bool zeroForOne, uint256 amount, bool exactInput)
        internal
        view
        returns (bool)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 parity = uint160(FixedPoint96.Q96);
        // zeroForOne pushes sqrtPriceX96 down (worse for a trader paying currency0); oneForZero pushes
        // it up (worse for a trader paying currency1). Route through CTF once the pool is already on
        // the trader-unfavorable side of parity for this direction.
        if (zeroForOne ? sqrtPriceX96 <= parity : sqrtPriceX96 >= parity) return true;

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return false;

        uint160 projected = exactInput
            ? SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amount, zeroForOne)
            : SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceX96, liquidity, amount, zeroForOne);
        return zeroForOne ? projected <= parity : projected >= parity;
    }

    // ---------------------------------------------------------------------
    // Inventory recycling
    // ---------------------------------------------------------------------

    /// @dev Tags the payload `unlockCallback` receives, since both {sweepClaims} and
    /// {harvestOpportunisticSurplus} need their own `PoolManager.unlock` (nested unlocks are not
    /// supported, so each must run in its own top-level call) and route through the same callback.
    enum UnlockAction {
        Sweep,
        Harvest
    }

    /// @inheritdoc ICompleteSetInternalizationHook
    function sweepClaims(PoolKey calldata key) external returns (uint256 yesSwept, uint256 noSwept) {
        PoolId poolId = key.toId();
        _getRegisteredMarket(poolId); // reverts if unregistered
        bytes memory result = poolManager.unlock(abi.encode(UnlockAction.Sweep, abi.encode(poolId)));
        (yesSwept, noSwept) = abi.decode(result, (uint256, uint256));
    }

    /// @inheritdoc ICompleteSetInternalizationHook
    function harvestOpportunisticSurplus(PoolKey calldata key, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountMerged, uint256 surplus)
    {
        PoolId poolId = key.toId();
        Market storage market = _getRegisteredMarket(poolId);
        if (market.frozen) revert MarketFrozen(poolId);
        if (amountIn == 0) revert ZeroAmount();

        // Only ever trade the market's currently idle (unmatched) inventory — the matched, mergeable
        // portion (and `collateralReserve`) is never touched, so the mergeable amount can only stay the
        // same or grow from this call, never shrink. See {ICompleteSetInternalizationHook-harvestOpportunisticSurplus}.
        bool sellYes = market.yesInventory > market.noInventory;
        uint256 idle = sellYes ? market.yesInventory - market.noInventory : market.noInventory - market.yesInventory;
        if (amountIn > idle) revert InsufficientIdleInventory(amountIn, idle);

        bytes memory result =
            poolManager.unlock(abi.encode(UnlockAction.Harvest, abi.encode(key, sellYes, amountIn, minAmountOut)));
        (amountMerged, surplus) = abi.decode(result, (uint256, uint256));
    }

    /// @dev `PoolManager` callback for {sweepClaims} and {harvestOpportunisticSurplus}. Only reachable
    /// via `poolManager.unlock`, which only this contract ever calls, always with one of the two
    /// `UnlockAction`-tagged payloads built above, so `data` is trusted to decode accordingly.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (UnlockAction action, bytes memory payload) = abi.decode(data, (UnlockAction, bytes));
        if (action == UnlockAction.Sweep) {
            return _handleSweep(abi.decode(payload, (PoolId)));
        }
        (PoolKey memory key, bool sellYes, uint256 amountIn, uint256 minAmountOut) =
            abi.decode(payload, (PoolKey, bool, uint256, uint256));
        return _handleHarvest(key, sellYes, amountIn, minAmountOut);
    }

    function _handleSweep(PoolId poolId) private returns (bytes memory) {
        Market storage market = _markets[poolId];

        uint256 yesSwept = CompleteSetLib.sweepLeg(
            conditionalTokens, wrapped1155Factory, poolManager, market.yesCurrency, market.yesPositionId, market.yesWrapData, market.yesClaimBalance
        );
        market.yesClaimBalance = 0;
        market.yesInventory += yesSwept;

        uint256 noSwept = CompleteSetLib.sweepLeg(
            conditionalTokens, wrapped1155Factory, poolManager, market.noCurrency, market.noPositionId, market.noWrapData, market.noClaimBalance
        );
        market.noClaimBalance = 0;
        market.noInventory += noSwept;

        if (yesSwept > 0 || noSwept > 0) emit ClaimsSwept(poolId, yesSwept, noSwept);
        return abi.encode(yesSwept, noSwept);
    }

    /// @dev Sells `amountIn` of the market's idle `sellYes ? YES : NO` leg directly against this pool's
    /// own AMM curve for the other leg (via {CompleteSetLib-sellIdleLegOnCurve}), then merges. Calling
    /// `poolManager.swap` directly (not via a router) makes this hook the swap's own `msg.sender`, which
    /// `Hooks.beforeSwap`/`afterSwap` special-case to skip invoking the hook entirely — so this executes
    /// as a plain AMM-curve trade and does not re-trigger mechanism A's CTF backstop on itself.
    function _handleHarvest(PoolKey memory key, bool sellYes, uint256 amountIn, uint256 minAmountOut)
        private
        returns (bytes memory)
    {
        PoolId poolId = key.toId();
        Market storage market = _markets[poolId];

        uint256 amountOut = CompleteSetLib.sellIdleLegOnCurve(
            conditionalTokens, wrapped1155Factory, poolManager, key, market, sellYes, amountIn, minAmountOut
        );

        if (sellYes) {
            market.yesInventory -= amountIn;
            market.noInventory += amountOut;
        } else {
            market.noInventory -= amountIn;
            market.yesInventory += amountOut;
        }
        emit OpportunisticSwap(poolId, sellYes, amountIn, amountOut);

        (uint256 amountMerged, uint256 surplus) = _mergeIfPossible(poolId, market);
        return abi.encode(amountMerged, surplus);
    }

    /// @inheritdoc ICompleteSetInternalizationHook
    function mergeIfPossible(PoolKey calldata key) external returns (uint256 amountMerged, uint256 surplus) {
        PoolId poolId = key.toId();
        Market storage market = _getRegisteredMarket(poolId);
        if (market.yesClaimBalance > 0 || market.noClaimBalance > 0) {
            poolManager.unlock(abi.encode(UnlockAction.Sweep, abi.encode(poolId)));
        }
        return _mergeIfPossible(poolId, market);
    }

    function _mergeIfPossible(PoolId poolId, Market storage market)
        private
        returns (uint256 amountMerged, uint256 surplus)
    {
        amountMerged = market.yesInventory < market.noInventory ? market.yesInventory : market.noInventory;
        if (amountMerged == 0) return (0, 0);

        uint256 balanceBefore = market.collateralToken.balanceOf(address(this));
        conditionalTokens.mergePositions(
            market.collateralToken, bytes32(0), market.conditionId, CompleteSetLib.binaryPartition(), amountMerged
        );
        uint256 proceeds = market.collateralToken.balanceOf(address(this)) - balanceBefore;

        market.yesInventory -= amountMerged;
        market.noInventory -= amountMerged;

        uint256 recoveredCost = amountMerged < market.outstandingSplitCost ? amountMerged : market.outstandingSplitCost;
        market.outstandingSplitCost -= recoveredCost;
        surplus = proceeds - recoveredCost;

        market.collateralReserve += proceeds;
        if (surplus > 0) market.lifetimeSurplus += surplus;

        emit InventoryMerged(poolId, amountMerged, surplus);
    }

    // ---------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------

    /// @inheritdoc ICompleteSetInternalizationHook
    function freezeForResolution(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        Market storage market = _getRegisteredMarket(poolId);
        if (conditionalTokens.payoutDenominator(market.conditionId) == 0) {
            revert ConditionNotYetResolved(market.conditionId);
        }
        market.frozen = true;
        emit MarketFrozenForResolution(poolId);
    }

    /// @inheritdoc ICompleteSetInternalizationHook
    function redeemAfterResolution(PoolKey calldata key) external returns (uint256 collateralReceived) {
        PoolId poolId = key.toId();
        Market storage market = _getRegisteredMarket(poolId);
        if (!market.frozen) revert MarketFrozen(poolId);

        uint256 balanceBefore = market.collateralToken.balanceOf(address(this));
        conditionalTokens.redeemPositions(
            market.collateralToken, bytes32(0), market.conditionId, CompleteSetLib.binaryPartition()
        );
        collateralReceived = market.collateralToken.balanceOf(address(this)) - balanceBefore;

        market.yesInventory = 0;
        market.noInventory = 0;
        market.collateralReserve += collateralReceived;

        emit MarketRedeemed(poolId, collateralReceived);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc ICompleteSetInternalizationHook
    function getMarket(PoolId poolId) external view returns (Market memory) {
        return _markets[poolId];
    }

    function _getRegisteredMarket(PoolId poolId) private view returns (Market storage market) {
        market = _markets[poolId];
        if (!market.registered) revert MarketNotRegistered(poolId);
    }
}
