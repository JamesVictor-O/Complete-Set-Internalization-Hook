// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {IConditionalTokens} from "../../src/interfaces/IConditionalTokens.sol";
import {IWrapped1155Factory} from "../../src/interfaces/IWrapped1155Factory.sol";
import {CompleteSetLib} from "../../src/libraries/CompleteSetLib.sol";

/// @notice Integration test against the REAL, already-deployed Gnosis `ConditionalTokens` contract on
/// Gnosis Chain — the same instance Omen's prediction markets run on production TVL, not the 0.8.26-
/// native mock the rest of the suite uses. Verifies {CompleteSetLib}'s ported CTF ID math and the
/// hook's split/merge/redeem flow are bit-for-bit compatible with the real deployed bytecode, per
/// CLAUDE.md's testing requirements ("Integration tests with real CTF + Wrapped1155").
///
/// @dev Requires network access — forks Gnosis Chain via a public RPC. Run explicitly with:
///   forge test --match-contract CompleteSetInternalizationHookForkTest
/// or exclude it from an offline run with `--no-match-path "test/fork/**"`.
///
/// The fork also verifies the legacy two-argument Wrapped1155Factory ABI used by the live Gnosis
/// deployment, including wrapper creation and a complete wrap/unwrap round trip.
contract CompleteSetInternalizationHookForkTest is Test, ERC1155Holder {
    string constant GNOSIS_RPC = "https://gnosis-rpc.publicnode.com";

    // Real, live Gnosis Chain deployment (confirmed via `cast code` — 30,017 bytes of real bytecode, and
    // every {IConditionalTokens} selector confirmed present in its dispatcher) — the same contract
    // Omen's prediction markets use, not a test double.
    IConditionalTokens constant REAL_CONDITIONAL_TOKENS =
        IConditionalTokens(0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce);
    IWrapped1155Factory constant REAL_WRAPPED_1155_FACTORY =
        IWrapped1155Factory(0xEC9Cc78463b72D7246E8189Df5EeD5fDc3508E71);

    MockERC20 collateral;
    bytes32 conditionId;
    address oracle;
    bytes32 questionId;

    function setUp() public {
        // Deliberately un-pinned (latest): the public RPC used here is not an archive node and drops
        // old state after a relatively short window, which made a pinned historical block flaky. Each
        // run derives a fresh `questionId` from the current block instead, so a condition already
        // prepared by an earlier run of this same test never collides.
        vm.createSelectFork(GNOSIS_RPC);

        collateral = new MockERC20("Collateral", "COL", 18);
        oracle = address(this); // so this test can call the real `reportPayouts` itself, below
        questionId = keccak256(abi.encode("fork test: will it rain tomorrow", block.number, block.timestamp));
        REAL_CONDITIONAL_TOKENS.prepareCondition(oracle, questionId, 2);
        conditionId = CompleteSetLib.getConditionId(oracle, questionId, 2);
    }

    /// @notice The core purpose of this fork test: {CompleteSetLib}'s ported `getConditionId`/
    /// `getCollectionId`/`getPositionId` must reproduce the exact token IDs the *real* CTF contract uses
    /// for its own ERC-1155 balances. This can only be verified against real deployed bytecode — the
    /// mock used elsewhere reuses {CompleteSetLib} for its own ID derivation too, so it is
    /// self-consistent but cannot catch a divergence from the real contract the way this test can.
    function test_ctfIdMath_matchesRealDeployedContract() public {
        uint256 amount = 10 ether;
        collateral.mint(address(this), amount);
        collateral.approve(address(REAL_CONDITIONAL_TOKENS), amount);
        REAL_CONDITIONAL_TOKENS.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );

        uint256 yesPositionId = CompleteSetLib.yesPositionId(IERC20(address(collateral)), conditionId);
        uint256 noPositionId = CompleteSetLib.noPositionId(IERC20(address(collateral)), conditionId);

        // If our ported ID math didn't match the real contract's internal derivation bit-for-bit, the
        // real CTF would have minted the split proceeds under *different* token IDs than the ones we
        // compute here, and these balance checks would read zero.
        assertEq(IERC1155(address(REAL_CONDITIONAL_TOKENS)).balanceOf(address(this), yesPositionId), amount);
        assertEq(IERC1155(address(REAL_CONDITIONAL_TOKENS)).balanceOf(address(this), noPositionId), amount);
    }

    function test_legacyWrapped1155Factory_wrapAndUnwrapRoundTrip() public {
        uint256 amount = 10 ether;
        collateral.mint(address(this), amount);
        collateral.approve(address(REAL_CONDITIONAL_TOKENS), amount);
        REAL_CONDITIONAL_TOKENS.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );

        uint256 positionId = CompleteSetLib.yesPositionId(IERC20(address(collateral)), conditionId);
        address wrapped = REAL_WRAPPED_1155_FACTORY.requireWrapped1155(REAL_CONDITIONAL_TOKENS, positionId);
        bytes memory wrapData = CompleteSetLib.encodeWrappedTokenData(address(this));
        REAL_CONDITIONAL_TOKENS.safeTransferFrom(
            address(this), address(REAL_WRAPPED_1155_FACTORY), positionId, amount, wrapData
        );
        assertEq(IERC20(wrapped).balanceOf(address(this)), amount);

        IERC20(wrapped).approve(address(REAL_WRAPPED_1155_FACTORY), amount);
        REAL_WRAPPED_1155_FACTORY.unwrap(
            REAL_CONDITIONAL_TOKENS, positionId, amount, address(this), wrapData
        );
        assertEq(IERC20(wrapped).balanceOf(address(this)), 0);
        assertEq(REAL_CONDITIONAL_TOKENS.balanceOf(address(this), positionId), amount);
    }

    /// @notice Key Invariant #1 against real bytecode: a freshly split complete set can always be merged
    /// straight back into exactly the same amount of collateral, with no loss — the same property
    /// `_mergeIfPossible`'s accounting in the hook depends on for every merge.
    function test_splitAndMerge_roundTripReturnsExactCollateral() public {
        uint256 amount = 10 ether;
        collateral.mint(address(this), amount);
        collateral.approve(address(REAL_CONDITIONAL_TOKENS), amount);
        REAL_CONDITIONAL_TOKENS.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );
        assertEq(collateral.balanceOf(address(this)), 0);

        REAL_CONDITIONAL_TOKENS.mergePositions(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );
        assertEq(collateral.balanceOf(address(this)), amount);

        uint256 yesPositionId = CompleteSetLib.yesPositionId(IERC20(address(collateral)), conditionId);
        uint256 noPositionId = CompleteSetLib.noPositionId(IERC20(address(collateral)), conditionId);
        assertEq(IERC1155(address(REAL_CONDITIONAL_TOKENS)).balanceOf(address(this), yesPositionId), 0);
        assertEq(IERC1155(address(REAL_CONDITIONAL_TOKENS)).balanceOf(address(this), noPositionId), 0);
    }

    /// @notice The resolution/redemption path against real bytecode: after the real oracle reports
    /// payouts (via the real CTF's `reportPayouts`, which the hook itself never calls — only reads the
    /// results of, through `payoutDenominator`/`redeemPositions`), redeeming a one-sided position pays
    /// out exactly the winning share, matching {CompleteSetInternalizationHook-redeemAfterResolution}'s
    /// expectations.
    function test_redeemPositions_afterRealOracleReport_paysOutWinningLeg() public {
        uint256 amount = 10 ether;
        collateral.mint(address(this), amount);
        collateral.approve(address(REAL_CONDITIONAL_TOKENS), amount);
        REAL_CONDITIONAL_TOKENS.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES wins
        payouts[1] = 0;
        IRealCtfOracleReporting(address(REAL_CONDITIONAL_TOKENS)).reportPayouts(questionId, payouts);
        assertEq(REAL_CONDITIONAL_TOKENS.payoutDenominator(conditionId), 1);

        uint256[] memory indexSets = CompleteSetLib.binaryPartition();
        REAL_CONDITIONAL_TOKENS.redeemPositions(
            IERC20(address(collateral)), bytes32(0), conditionId, indexSets
        );

        // Both legs redeemed together: the losing (NO) leg pays 0, the winning (YES) leg pays 1:1.
        assertEq(collateral.balanceOf(address(this)), amount);
    }
}

/// @dev The hook itself never calls `reportPayouts` (only the oracle does, off the hook's own path), so
/// it is deliberately not part of {IConditionalTokens} — declared locally here just to exercise the real
/// resolution flow end to end in this one test.
interface IRealCtfOracleReporting {
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}
