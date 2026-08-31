// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {CompleteSetLib} from "../src/libraries/CompleteSetLib.sol";

/// @notice Pure-math sanity checks for {CompleteSetLib}'s ported CTF ID derivation. These don't prove
/// bit-for-bit equivalence with the real Gnosis CTF bytecode (that requires the deployed contract itself
/// — see {MockConditionalTokens}'s NatSpec) but they do lock in the properties the hook actually depends
/// on: determinism, and that YES and NO never collide.
contract CompleteSetLibTest is Test {
    IERC20 constant COLLATERAL = IERC20(address(0xC011A7E7A1));
    bytes32 constant CONDITION_ID = keccak256("condition");

    function test_binaryPartition_isYesThenNo() public pure {
        uint256[] memory partition = CompleteSetLib.binaryPartition();
        assertEq(partition.length, 2);
        assertEq(partition[0], CompleteSetLib.YES_INDEX_SET);
        assertEq(partition[1], CompleteSetLib.NO_INDEX_SET);
    }

    function test_yesAndNoPositionIds_areDeterministicAndDistinct() public view {
        uint256 yes1 = CompleteSetLib.yesPositionId(COLLATERAL, CONDITION_ID);
        uint256 yes2 = CompleteSetLib.yesPositionId(COLLATERAL, CONDITION_ID);
        uint256 no1 = CompleteSetLib.noPositionId(COLLATERAL, CONDITION_ID);

        assertEq(yes1, yes2, "yesPositionId must be deterministic");
        assertNotEq(yes1, no1, "YES and NO must never share a position id");
    }

    function test_positionId_dependsOnCollateralToken() public view {
        IERC20 otherCollateral = IERC20(address(0xC011A7E7A2));
        uint256 yesA = CompleteSetLib.yesPositionId(COLLATERAL, CONDITION_ID);
        uint256 yesB = CompleteSetLib.yesPositionId(otherCollateral, CONDITION_ID);
        assertNotEq(yesA, yesB);
    }

    function test_conditionId_dependsOnAllInputs() public pure {
        bytes32 id1 = CompleteSetLib.getConditionId(address(1), bytes32(uint256(1)), 2);
        bytes32 id2 = CompleteSetLib.getConditionId(address(2), bytes32(uint256(1)), 2);
        bytes32 id3 = CompleteSetLib.getConditionId(address(1), bytes32(uint256(2)), 2);
        assertNotEq(id1, id2);
        assertNotEq(id1, id3);
    }

    function test_encodeWrappedTokenData_encodesLegacyFactoryOperatorRecipient() public pure {
        address recipient = address(0xBEEF);
        bytes memory data = CompleteSetLib.encodeWrappedTokenData(recipient);
        assertEq(data.length, 32);
        assertEq(abi.decode(data, (address)), recipient);
    }
}
