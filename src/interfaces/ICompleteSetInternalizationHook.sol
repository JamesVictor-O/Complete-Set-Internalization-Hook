// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title ICompleteSetInternalizationHook
/// @notice External interface, events, errors, and shared types for the Complete-Set Internalization
/// Hook. See CLAUDE.md at the repo root for the invariants this hook must never violate.
interface ICompleteSetInternalizationHook {
    /// @notice Per-pool state for one binary market (a YES/NO pair backed by one CTF condition).
    /// @dev `collateralReserve` is the hook's *entire* liquid, deployable-or-withdrawable pool for this
    /// market: seed deposits plus every collateral unit recovered from a merge or a post-resolution
    /// redemption. It is the sole NAV numerator behind `totalShares` — there is no separate "surplus"
    /// balance, because any realized surplus is just collateral flowing back into this same reserve.
    /// `yesInventory` / `noInventory` are *not* part of NAV until merged; they are outcome tokens the
    /// hook is currently holding, not yet-recovered collateral.
    struct Market {
        bool registered;
        bool frozen;
        IERC20 collateralToken;
        bytes32 conditionId;
        Currency yesCurrency;
        Currency noCurrency;
        uint256 yesPositionId;
        uint256 noPositionId;
        bytes yesWrapData;
        bytes noWrapData;
        uint256 collateralReserve;
        uint256 outstandingSplitCost;
        uint256 yesInventory;
        uint256 noInventory;
        // Pending ERC-6909 claims on YES/NO minted during a fill for the currency the trader paid in.
        // A `PoolManager` swap hook can never receive the trader's payment as *real* ERC-20 mid-swap —
        // the router only physically settles it after `swap()` returns, which is after `beforeSwap`
        // already ran (see {CompleteSetInternalizationHook-_fillFromCompleteSet}). Claims capture that
        // value immediately; {sweepClaims} converts them into real, CTF-usable inventory once the
        // router's settlement has actually landed, which requires its own `PoolManager.unlock` and so
        // cannot happen inside the same `beforeSwap` call.
        uint256 yesClaimBalance;
        uint256 noClaimBalance;
        uint256 totalShares;
        uint256 lifetimeSurplus;
    }

    // ---------------------------------------------------------------------
    // Events — one per state change that moves collateral, inventory, or market status.
    // ---------------------------------------------------------------------

    /// @notice A binary market was registered against a pool.
    event MarketRegistered(
        PoolId indexed poolId,
        bytes32 indexed conditionId,
        address indexed collateralToken,
        address yesToken,
        address noToken
    );

    /// @notice An LP deposited collateral into a market's reserve.
    event CollateralDeposited(PoolId indexed poolId, address indexed provider, uint256 amount, uint256 sharesMinted);

    /// @notice An LP withdrew collateral from a market's reserve.
    event CollateralWithdrawn(PoolId indexed poolId, address indexed provider, uint256 amount, uint256 sharesBurned);

    /// @notice A swap was filled off the CTF complete-set invariant instead of the AMM curve, and the
    /// hook returned a pure NoOp `BeforeSwapDelta` — the `PoolManager` did not touch its own curve.
    event CompleteSetFilled(PoolId indexed poolId, address indexed trader, bool zeroForOne, uint256 amount);

    /// @notice The hook merged its own YES/NO inventory back into collateral.
    /// @param surplus Collateral recovered beyond what mechanism (A) fills had spent acquiring this
    /// inventory; zero unless the hook acquired outcome tokens through some other, cheaper route.
    event InventoryMerged(PoolId indexed poolId, uint256 amountMerged, uint256 surplus);

    /// @notice Pending ERC-6909 claims from past fills were converted into real, CTF-usable inventory.
    event ClaimsSwept(PoolId indexed poolId, uint256 yesSwept, uint256 noSwept);

    /// @notice The hook sold `amountIn` of its idle (currently-unmatched) YES/NO inventory directly
    /// against this pool's own AMM curve for `amountOut` of the other leg, as part of
    /// {harvestOpportunisticSurplus}.
    event OpportunisticSwap(PoolId indexed poolId, bool soldYes, uint256 amountIn, uint256 amountOut);

    /// @notice A market was frozen ahead of CTF resolution; no further swaps are routed for it.
    event MarketFrozenForResolution(PoolId indexed poolId);

    /// @notice The hook redeemed its remaining post-resolution inventory for collateral.
    event MarketRedeemed(PoolId indexed poolId, uint256 collateralReceived);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error MarketAlreadyRegistered(PoolId poolId);
    error MarketNotRegistered(PoolId poolId);
    error ConditionNotBinary(bytes32 conditionId, uint256 outcomeSlotCount);
    error ConditionAlreadyResolved(bytes32 conditionId);
    error ConditionNotYetResolved(bytes32 conditionId);
    error CurrencyMismatch(Currency expected, Currency actual);
    error MarketFrozen(PoolId poolId);
    error ZeroAmount();
    error InsufficientShares(uint256 requested, uint256 available);
    /// @dev Thrown by {harvestOpportunisticSurplus} when `amountIn` exceeds the market's currently idle
    /// (unmatched) inventory — this function may only trade already-idle inventory, never dip into the
    /// matched portion or `collateralReserve`.
    error InsufficientIdleInventory(uint256 requested, uint256 available);
    /// @dev Thrown by {harvestOpportunisticSurplus} when the AMM curve would return less than what was
    /// sold in (or less than the caller's own `minAmountOut`, if stricter) — this function is a hard
    /// no-lose operation by construction, not merely a caller-supplied slippage convention.
    error SlippageExceeded(uint256 amountOut, uint256 required);

    // ---------------------------------------------------------------------
    // External API
    // ---------------------------------------------------------------------

    /// @notice Registers a binary market for `key`, wiring it to an already-prepared CTF condition.
    /// @dev Reverts unless `key.currency0`/`key.currency1` are exactly the wrapped YES/NO ERC-20s that
    /// `conditionId` and `collateralToken` deterministically produce — the market's identity is
    /// self-authenticating, so this function is intentionally permissionless.
    /// The name/symbol arguments are retained for caller compatibility but ignored by the legacy
    /// Gnosis factory, whose wrappers use fixed metadata.
    function registerMarket(
        PoolKey calldata key,
        IERC20 collateralToken,
        bytes32 conditionId,
        string calldata yesName,
        string calldata yesSymbol,
        string calldata noName,
        string calldata noSymbol
    ) external;

    /// @notice Deposits `amount` of a market's collateral token into its reserve, minting LP shares.
    function depositCollateral(PoolKey calldata key, uint256 amount) external returns (uint256 sharesMinted);

    /// @notice Burns `shares` and withdraws the proportional amount of a market's *liquid* reserve.
    /// @dev Only `collateralReserve` is withdrawable; collateral currently deployed as unmerged YES/NO
    /// inventory is not liquid until a merge brings it back into the reserve.
    function withdrawCollateral(PoolKey calldata key, uint256 shares) external returns (uint256 amountOut);

    /// @notice Converts a market's pending YES/NO claim balances (see {Market}) into real, CTF-usable
    /// inventory. Opens its own `PoolManager.unlock` — callable any time after a fill lands in a
    /// separate, later transaction, once the router that drove that swap has actually settled real
    /// tokens into the pool.
    function sweepClaims(PoolKey calldata key) external returns (uint256 yesSwept, uint256 noSwept);

    /// @notice Permissionlessly sweeps pending claims, then merges as much of a market's YES/NO
    /// inventory as currently overlaps.
    function mergeIfPossible(PoolKey calldata key) external returns (uint256 amountMerged, uint256 surplus);

    /// @notice Opportunistically converts a market's idle YES/NO inventory imbalance into LP surplus:
    /// sells `amountIn` of the currently-excess (unmatched) leg directly against this pool's own AMM
    /// curve for the deficient leg, then merges. Only ever trades inventory that is already idle — never
    /// `collateralReserve` — and reverts unless the trade returns at least `amountIn` (and at least
    /// `minAmountOut`, if stricter), so this can never reduce LP-liquid capital or the market's total
    /// mergeable value.
    /// @param amountIn Amount of the excess leg to sell; must not exceed the current idle imbalance.
    /// @param minAmountOut Caller-supplied minimum output; the effective floor is
    /// `max(amountIn, minAmountOut)`.
    function harvestOpportunisticSurplus(PoolKey calldata key, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountMerged, uint256 surplus);

    /// @notice Freezes a market once its CTF condition has been resolved. No swaps are routed for a
    /// frozen market; standard AMM swaps on the pool remain the caller's own business, this only stops
    /// the hook from filling further complete-set trades against stale reserve/inventory.
    function freezeForResolution(PoolKey calldata key) external;

    /// @notice Redeems the hook's remaining YES/NO inventory for collateral after resolution.
    function redeemAfterResolution(PoolKey calldata key) external returns (uint256 collateralReceived);

    /// @notice Returns the full stored state for a market.
    function getMarket(PoolId poolId) external view returns (Market memory);
}
