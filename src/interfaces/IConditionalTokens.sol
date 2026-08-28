// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

/// @title IConditionalTokens
/// @notice Minimal 0.8.x-compatible interface for the Gnosis Conditional Tokens Framework (CTF).
/// @dev The real `ConditionalTokens` contract (lib/conditional-tokens-contracts) is pragma ^0.5.1 and
/// cannot be imported directly into this ^0.8.26 project without forcing a second compiler version.
/// This interface only declares the surface the hook actually calls; the ABI is identical to the
/// deployed contract, so calls made through this interface reach the real CTF correctly.
interface IConditionalTokens is IERC1155 {
    /// @notice Prepares a condition, initializing its payout vector.
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    /// @notice Splits `amount` of collateral (or a parent position) into the positions in `partition`.
    /// @dev Pulls `amount` of `collateralToken` from the caller via `transferFrom` when
    /// `parentCollectionId == bytes32(0)`. The caller must have approved this contract beforehand.
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    /// @notice Merges `amount` of the positions in `partition` back into collateral (or a parent position).
    /// @dev Burns the caller's ERC-1155 balance in each position of `partition`; the caller does not need
    /// prior ERC-1155 approval since it burns its own balance.
    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    /// @notice Redeems the caller's positions in `indexSets` for collateral after resolution.
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;

    /// @notice Number of outcome slots for a condition, or zero if it has not been prepared.
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);

    /// @notice Payout numerator for a single outcome slot of a condition. Zero for every slot until resolved.
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);

    /// @notice Sum of payout numerators for a condition. Non-zero only once the condition is resolved.
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
}
