// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "openzeppelin/token/ERC1155/ERC1155.sol";
import {IERC165} from "openzeppelin/utils/introspection/IERC165.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IConditionalTokens} from "../../src/interfaces/IConditionalTokens.sol";
import {CompleteSetLib} from "../../src/libraries/CompleteSetLib.sol";

/// @title MockConditionalTokens
/// @notice A minimal, ^0.8.26-native re-implementation of the Gnosis CTF split/merge/redeem lifecycle
/// for binary conditions, used only in tests.
/// @dev The real `ConditionalTokens` (lib/conditional-tokens-contracts) is pragma ^0.5.1 and cannot be
/// imported into this project (see {IConditionalTokens}). This mock reproduces its economically
/// relevant behavior — split/merge/redeem accounting and the `payoutNumerators`/`payoutDenominator`
/// resolution lifecycle — closely enough to exercise the hook end-to-end. It intentionally reuses
/// {CompleteSetLib} for position/collection ID derivation so IDs the hook computes locally always match
/// IDs this mock mints/burns against; that is a self-consistency property useful for testing the hook's
/// own logic, not an independent verification that {CompleteSetLib} matches the real CTF bytecode.
/// Before mainnet deployment, run the integration suite against the real deployed contracts too.
contract MockConditionalTokens is ERC1155, IConditionalTokens {
    using SafeERC20 for IERC20;
    using CompleteSetLib for IERC20;

    mapping(bytes32 => uint256) public outcomeSlotCountOf;
    mapping(bytes32 => uint256[]) internal _payoutNumerators;
    mapping(bytes32 => uint256) public payoutDenominatorOf;

    constructor() ERC1155("") {}

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external {
        bytes32 conditionId = CompleteSetLib.getConditionId(oracle, questionId, outcomeSlotCount);
        require(outcomeSlotCountOf[conditionId] == 0, "already prepared");
        outcomeSlotCountOf[conditionId] = outcomeSlotCount;
    }

    /// @notice Test-only shortcut: reports payouts directly by conditionId (skips oracle/questionId
    /// hashing, unlike the real CTF's `reportPayouts`), since tests only need a resolved denominator.
    function reportPayoutsForTest(bytes32 conditionId, uint256[] calldata payouts) external {
        require(outcomeSlotCountOf[conditionId] == payouts.length, "bad outcome count");
        require(payoutDenominatorOf[conditionId] == 0, "already resolved");
        uint256 den;
        for (uint256 i = 0; i < payouts.length; i++) {
            den += payouts[i];
        }
        require(den > 0, "payout is all zeroes");
        _payoutNumerators[conditionId] = payouts;
        payoutDenominatorOf[conditionId] = den;
    }

    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(parentCollectionId == bytes32(0), "mock: parent positions not supported");
        require(outcomeSlotCountOf[conditionId] > 0, "not prepared");

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 positionId = collateralToken.getPositionId(
                CompleteSetLib.getCollectionId(parentCollectionId, conditionId, partition[i])
            );
            _mint(msg.sender, positionId, amount, "");
        }
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(parentCollectionId == bytes32(0), "mock: parent positions not supported");
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 positionId = collateralToken.getPositionId(
                CompleteSetLib.getCollectionId(parentCollectionId, conditionId, partition[i])
            );
            _burn(msg.sender, positionId, amount);
        }
        collateralToken.safeTransfer(msg.sender, amount);
    }

    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        require(parentCollectionId == bytes32(0), "mock: parent positions not supported");
        uint256 den = payoutDenominatorOf[conditionId];
        require(den > 0, "not resolved");
        uint256 outcomeSlotCount = outcomeSlotCountOf[conditionId];

        uint256 totalPayout;
        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 indexSet = indexSets[i];
            uint256 positionId = collateralToken.getPositionId(
                CompleteSetLib.getCollectionId(parentCollectionId, conditionId, indexSet)
            );

            uint256 payoutNumerator;
            for (uint256 j = 0; j < outcomeSlotCount; j++) {
                if (indexSet & (1 << j) != 0) payoutNumerator += _payoutNumerators[conditionId][j];
            }

            uint256 stake = balanceOf(msg.sender, positionId);
            if (stake > 0) {
                totalPayout += (stake * payoutNumerator) / den;
                _burn(msg.sender, positionId, stake);
            }
        }

        if (totalPayout > 0) collateralToken.safeTransfer(msg.sender, totalPayout);
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCountOf[conditionId];
    }

    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256) {
        return _payoutNumerators[conditionId][index];
    }

    function payoutDenominator(bytes32 conditionId) external view returns (uint256) {
        return payoutDenominatorOf[conditionId];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
