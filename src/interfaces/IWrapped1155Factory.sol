// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";

/// @title IWrapped1155Factory
/// @notice Minimal 0.8.x-compatible interface for Gnosis's Wrapped1155Factory.
/// @dev The real `Wrapped1155Factory` contract (lib/1155-to-20) is pragma >=0.6.0 and, like
/// `IConditionalTokens`, cannot be imported directly into this ^0.8.26 project. This interface is
/// ABI-compatible with the deployed contract.
///
/// `data` for every call below must be exactly 65 bytes: 32 bytes token name, 32 bytes token symbol,
/// 1 byte token decimals, packed left-to-right. See {CompleteSetLib.encodeWrappedTokenData}.
interface IWrapped1155Factory {
    /// @notice Deploys (if needed) and returns the ERC-20 wrapper for `multiToken`/`tokenId`.
    function requireWrapped1155(IERC1155 multiToken, uint256 tokenId, bytes calldata data) external returns (address);

    /// @notice Deterministically predicts the ERC-20 wrapper address without deploying it.
    function getWrapped1155(IERC1155 multiToken, uint256 tokenId, bytes calldata data) external view returns (address);

    /// @notice Burns `amount` of the caller's wrapped ERC-20 balance and returns the underlying ERC-1155.
    function unwrap(IERC1155 multiToken, uint256 tokenId, uint256 amount, address recipient, bytes calldata data)
        external;
}
