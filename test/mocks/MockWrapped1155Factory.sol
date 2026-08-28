// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin/token/ERC1155/utils/ERC1155Holder.sol";

import {IWrapped1155Factory} from "../../src/interfaces/IWrapped1155Factory.sol";

/// @dev Simple mintable/burnable ERC-20, mint/burn restricted to the factory that deployed it.
contract MockWrapped1155 is ERC20 {
    address public immutable factory;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        factory = msg.sender;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "MockWrapped1155: only factory");
        _;
    }

    function mint(address to, uint256 amount) external onlyFactory {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyFactory {
        _burn(from, amount);
    }
}

/// @title MockWrapped1155Factory
/// @notice A minimal, ^0.8.26-native stand-in for Gnosis's `Wrapped1155Factory`, used only in tests.
/// @dev The real factory (lib/1155-to-20) is pragma >=0.6.0 and cannot be imported into this project
/// (see {IWrapped1155Factory}). It also deterministically derives each wrapper's address via CREATE2 so
/// unrelated callers can predict it off-chain; this mock does not replicate that determinism (it just
/// deploys plain `MockWrapped1155` instances via `CREATE` and remembers them in a mapping) because
/// nothing in the hook or its tests relies on address prediction — only on `requireWrapped1155`,
/// `getWrapped1155`, and `unwrap` behaving consistently, which this preserves.
contract MockWrapped1155Factory is IWrapped1155Factory, ERC1155Holder {
    mapping(IERC1155 => mapping(uint256 => MockWrapped1155)) internal _wrapped;

    function requireWrapped1155(IERC1155 multiToken, uint256 tokenId, bytes calldata data)
        external
        override
        returns (address)
    {
        MockWrapped1155 wrapped = _wrapped[multiToken][tokenId];
        if (address(wrapped) != address(0)) return address(wrapped);

        (string memory name_, string memory symbol_) = _decodeNameSymbol(data);
        wrapped = new MockWrapped1155(name_, symbol_);
        _wrapped[multiToken][tokenId] = wrapped;
        return address(wrapped);
    }

    function getWrapped1155(IERC1155 multiToken, uint256 tokenId, bytes calldata) external view returns (address) {
        return address(_wrapped[multiToken][tokenId]);
    }

    function unwrap(IERC1155 multiToken, uint256 tokenId, uint256 amount, address recipient, bytes calldata data)
        external
    {
        _wrapped[multiToken][tokenId].burn(msg.sender, amount);
        multiToken.safeTransferFrom(address(this), recipient, tokenId, amount, data);
    }

    function onERC1155Received(address operator, address, uint256 id, uint256 value, bytes memory data)
        public
        override
        returns (bytes4)
    {
        MockWrapped1155 wrapped = _wrapped[IERC1155(msg.sender)][id];
        if (address(wrapped) == address(0)) {
            (string memory name_, string memory symbol_) = _decodeNameSymbol(data);
            wrapped = new MockWrapped1155(name_, symbol_);
            _wrapped[IERC1155(msg.sender)][id] = wrapped;
        }
        wrapped.mint(operator, value);
        return super.onERC1155Received(operator, address(0), id, value, data);
    }

    function _decodeNameSymbol(bytes memory data) internal pure returns (string memory name_, string memory symbol_) {
        require(data.length == 65, "MockWrapped1155Factory: bad data length");
        bytes32 nameWord;
        bytes32 symbolWord;
        assembly {
            nameWord := mload(add(data, 32))
            symbolWord := mload(add(data, 64))
        }
        name_ = _bytes32ToTrimmedString(nameWord);
        symbol_ = _bytes32ToTrimmedString(symbolWord);
    }

    function _bytes32ToTrimmedString(bytes32 raw) internal pure returns (string memory) {
        uint256 len;
        while (len < 32 && raw[len] != 0) len++;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = raw[i];
        }
        return string(out);
    }
}
