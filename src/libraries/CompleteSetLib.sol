// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IWrapped1155Factory} from "../interfaces/IWrapped1155Factory.sol";
import {ICompleteSetInternalizationHook} from "../interfaces/ICompleteSetInternalizationHook.sol";

/// @title CompleteSetLib
/// @notice Helper math for interacting with the Gnosis Conditional Tokens Framework (CTF) from
/// Solidity ^0.8.26, plus the binary-market constants used throughout the hook.
/// @dev CTF position/collection IDs are computed off the ERC-1155 token, not read from storage, so any
/// caller that needs to know a position's token ID (to check balances, wrap it, transfer it, ...) must
/// reproduce the exact same math the CTF contract uses internally in `CTHelpers.sol`
/// (lib/conditional-tokens-contracts/contracts/CTHelpers.sol, pragma ^0.5.1). That file cannot be
/// imported into this ^0.8.26 project (see {IConditionalTokens}), so its `getConditionId`,
/// `getCollectionId`, and `getPositionId` are ported here verbatim, with `uint` widened to `uint256`.
/// Values MUST match the original bit-for-bit; this is not free-form design, it is a straight port.
library CompleteSetLib {
    using CurrencySettler for Currency;

    /// @dev Index set for the YES outcome slot (slot 0) in a 2-outcome (binary) condition.
    uint256 internal constant YES_INDEX_SET = 1; // 0b01
    /// @dev Index set for the NO outcome slot (slot 1) in a 2-outcome (binary) condition.
    uint256 internal constant NO_INDEX_SET = 2; // 0b10
    /// @dev Number of outcome slots in a binary market. Every condition this hook touches must have
    /// exactly this many slots — the accounting below assumes YES + NO is the *entire* outcome set.
    uint256 internal constant BINARY_OUTCOME_SLOT_COUNT = 2;

    /// @notice The full-set partition `[YES, NO]` used for every split/merge in a binary market.
    function binaryPartition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = YES_INDEX_SET;
        partition[1] = NO_INDEX_SET;
    }

    // NOTE: getConditionId/getPositionId/getCollectionId/yesPositionId/noPositionId below are `public`,
    // not `internal`, on purpose. `getCollectionId` ports CTHelpers' full modular-sqrt routine, which is
    // large; declaring these `internal` would inline that code into every contract that uses the
    // library (blowing the hook past the EIP-170 24KB deployed-code limit). `public` library functions
    // deploy once as their own contract and are reached via `DELEGATECALL`, so callers only pay a few
    // bytes for the call, not the routine's full bytecode. This means `CompleteSetLib` must be deployed
    // and linked before `CompleteSetInternalizationHook` — Foundry does this automatically for tests and
    // scripts that reference the library by name.

    /// @dev Ported from CTHelpers.getConditionId (lib/conditional-tokens-contracts/contracts/CTHelpers.sol).
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    /// @dev Ported from CTHelpers.getPositionId.
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    /// @notice The ERC-1155 token ID for the YES leg of `conditionId`, backed by `collateralToken`.
    function yesPositionId(IERC20 collateralToken, bytes32 conditionId) public view returns (uint256) {
        return getPositionId(collateralToken, getCollectionId(bytes32(0), conditionId, YES_INDEX_SET));
    }

    /// @notice The ERC-1155 token ID for the NO leg of `conditionId`, backed by `collateralToken`.
    function noPositionId(IERC20 collateralToken, bytes32 conditionId) public view returns (uint256) {
        return getPositionId(collateralToken, getCollectionId(bytes32(0), conditionId, NO_INDEX_SET));
    }

    /// @notice Packs a wrapped-ERC20 name/symbol/decimals into the 65-byte `data` layout
    /// `Wrapped1155Factory` expects: 32 bytes name, 32 bytes symbol, 1 byte decimals.
    /// @dev Names/symbols longer than 32 bytes are truncated by the `bytes32` cast, matching the
    /// factory's own fixed-width encoding.
    function encodeWrappedTokenData(string memory name, string memory symbol, uint8 decimals)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes32(bytes(name)), bytes32(bytes(symbol)), decimals);
    }

    // -- Below: the CTF-call-heavy operations shared by the hook's swap and inventory-recycling paths.
    // `public` for the same reason as the ID-math functions above: keeping this code in one deployed
    // library contract (reached via `DELEGATECALL`) instead of inlining it into every caller is what
    // keeps `CompleteSetInternalizationHook` under the EIP-170 24KB deployed-code limit. Operates on the
    // caller's own storage (`Market storage`), exactly as if it were written inline in the hook. --

    /// @dev Executes one exact-input leg entirely off the CTF invariant at exactly 1:1: takes the pay
    /// leg as an ERC-6909 claim (see the hook's contract-level NatSpec for why), mints a fresh complete
    /// set from the reserve, and settles the receive leg back into the pool for real.
    function fillFromCompleteSet(
        IConditionalTokens conditionalTokens,
        IWrapped1155Factory wrapped1155Factory,
        IPoolManager poolManager,
        ICompleteSetInternalizationHook.Market storage market,
        Currency payCurrency,
        Currency receiveCurrency,
        uint256 amount
    ) public {
        bool payIsYes = payCurrency == market.yesCurrency;

        payCurrency.take(poolManager, address(this), amount, true);
        if (payIsYes) {
            market.yesClaimBalance += amount;
        } else {
            market.noClaimBalance += amount;
        }

        market.collateralReserve -= amount;
        market.outstandingSplitCost += amount;
        conditionalTokens.splitPosition(market.collateralToken, bytes32(0), market.conditionId, binaryPartition(), amount);

        (uint256 receivePositionId, bytes memory receiveWrapData) =
            payIsYes ? (market.noPositionId, market.noWrapData) : (market.yesPositionId, market.yesWrapData);
        conditionalTokens.safeTransferFrom(
            address(this), address(wrapped1155Factory), receivePositionId, amount, receiveWrapData
        );
        receiveCurrency.settle(poolManager, address(this), amount, false);

        if (payIsYes) {
            market.yesInventory += amount;
        } else {
            market.noInventory += amount;
        }
    }

    /// @dev Converts up to `claimBalance` of `currency`'s pending ERC-6909 claim into real, unwrapped
    /// CTF inventory: burns the claim, takes real tokens backed by it, then unwraps them. Must run
    /// inside a `PoolManager.unlock` (see {ICompleteSetInternalizationHook-sweepClaims}).
    function sweepLeg(
        IConditionalTokens conditionalTokens,
        IWrapped1155Factory wrapped1155Factory,
        IPoolManager poolManager,
        Currency currency,
        uint256 positionId,
        bytes memory wrapData,
        uint256 claimBalance
    ) public returns (uint256) {
        if (claimBalance == 0) return 0;
        currency.settle(poolManager, address(this), claimBalance, true);
        currency.take(poolManager, address(this), claimBalance, false);
        wrapped1155Factory.unwrap(conditionalTokens, positionId, claimBalance, address(this), wrapData);
        return claimBalance;
    }

    /// @dev Sells `amountIn` of the market's idle `sellYes ? YES : NO` leg directly against this pool's
    /// own AMM curve for the other leg, returning the amount received. Split into small private steps
    /// (wrap, swap+settle, unwrap) purely to stay under Solidity's legacy-codegen stack-depth limit; see
    /// {CompleteSetInternalizationHook-_handleHarvest} for the caller-side invariants this preserves
    /// (idle-only, hard no-lose floor). Does not update `market.{yes,no}Inventory` — the caller does that
    /// once, after this returns, since the exact bookkeeping split differs by which leg was sold.
    function sellIdleLegOnCurve(
        IConditionalTokens conditionalTokens,
        IWrapped1155Factory wrapped1155Factory,
        IPoolManager poolManager,
        PoolKey memory key,
        ICompleteSetInternalizationHook.Market storage market,
        bool sellYes,
        uint256 amountIn,
        uint256 minAmountOut
    ) public returns (uint256 amountOut) {
        Currency sellCurrency = sellYes ? market.yesCurrency : market.noCurrency;
        Currency buyCurrency = sellYes ? market.noCurrency : market.yesCurrency;
        bool zeroForOne = key.currency0 == sellCurrency;

        _wrapSellLeg(conditionalTokens, wrapped1155Factory, market, sellYes, amountIn);
        amountOut = _swapAndSettle(poolManager, key, zeroForOne, amountIn, minAmountOut, sellCurrency, buyCurrency);
        _unwrapBuyLeg(conditionalTokens, wrapped1155Factory, market, sellYes, amountOut);
    }

    function _wrapSellLeg(
        IConditionalTokens conditionalTokens,
        IWrapped1155Factory wrapped1155Factory,
        ICompleteSetInternalizationHook.Market storage market,
        bool sellYes,
        uint256 amountIn
    ) private {
        (uint256 positionId, bytes memory wrapData) =
            sellYes ? (market.yesPositionId, market.yesWrapData) : (market.noPositionId, market.noWrapData);
        conditionalTokens.safeTransferFrom(address(this), address(wrapped1155Factory), positionId, amountIn, wrapData);
    }

    function _swapAndSettle(
        IPoolManager poolManager,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        Currency sellCurrency,
        Currency buyCurrency
    ) private returns (uint256 amountOut) {
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        amountOut = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));

        // Hard no-lose floor enforced here, not left to the caller's `minAmountOut` alone: this
        // operation must never be able to reduce the market's total value.
        uint256 required = amountIn > minAmountOut ? amountIn : minAmountOut;
        if (amountOut < required) revert ICompleteSetInternalizationHook.SlippageExceeded(amountOut, required);

        sellCurrency.settle(poolManager, address(this), amountIn, false);
        buyCurrency.take(poolManager, address(this), amountOut, false);
    }

    function _unwrapBuyLeg(
        IConditionalTokens conditionalTokens,
        IWrapped1155Factory wrapped1155Factory,
        ICompleteSetInternalizationHook.Market storage market,
        bool sellYes,
        uint256 amountOut
    ) private {
        (uint256 positionId, bytes memory wrapData) =
            sellYes ? (market.noPositionId, market.noWrapData) : (market.yesPositionId, market.yesWrapData);
        wrapped1155Factory.unwrap(conditionalTokens, positionId, amountOut, address(this), wrapData);
    }

    // -- Below: verbatim port of CTHelpers.getCollectionId, including its private `sqrt` helper. --
    // The Gnosis CTF encodes an outcome collection ID as the x-coordinate of a point on the alt_bn128
    // curve, so that collection IDs can be combined (added) via the ecAdd precompile at address 0x06.
    // This is pure math with no external calls other than that precompile; it is deterministic and
    // must reproduce the original bit-for-bit or computed position IDs will not match the real CTF.

    uint256 private constant P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    uint256 private constant B = 3;

    /// @dev Ported from CTHelpers.getCollectionId.
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        public
        view
        returns (bytes32)
    {
        uint256 x1 = uint256(keccak256(abi.encodePacked(conditionId, indexSet)));
        bool odd = x1 >> 255 != 0;
        uint256 y1;
        uint256 yy;
        do {
            x1 = addmod(x1, 1, P);
            yy = addmod(mulmod(x1, mulmod(x1, x1, P), P), B, P);
            y1 = _sqrt(yy);
        } while (mulmod(y1, y1, P) != yy);
        if ((odd && y1 % 2 == 0) || (!odd && y1 % 2 == 1)) {
            y1 = P - y1;
        }

        uint256 x2 = uint256(parentCollectionId);
        if (x2 != 0) {
            odd = x2 >> 254 != 0;
            x2 = (x2 << 2) >> 2;
            yy = addmod(mulmod(x2, mulmod(x2, x2, P), P), B, P);
            uint256 y2 = _sqrt(yy);
            if ((odd && y2 % 2 == 0) || (!odd && y2 % 2 == 1)) {
                y2 = P - y2;
            }
            require(mulmod(y2, y2, P) == yy, "CompleteSetLib: invalid parent collection ID");

            (bool success, bytes memory ret) = address(6).staticcall(abi.encode(x1, y1, x2, y2));
            require(success, "CompleteSetLib: ecadd failed");
            (x1, y1) = abi.decode(ret, (uint256, uint256));
        }

        if (y1 % 2 == 1) {
            x1 ^= 1 << 254;
        }

        return bytes32(x1);
    }

    /// @dev Ported from CTHelpers.sqrt: modular square root mod P via exponentiation by (P+1)/4,
    /// since P % 4 == 3. Reverts are not possible here; the caller re-checks the result.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        uint256 p = P;
        assembly {
            // add chain generated via https://crypto.stackexchange.com/q/27179/71252
            // and transformed to the following program:

            // x=1; y=x+x; z=y+y; z=z+z; y=y+z; x=x+y; y=y+x; z=y+y; t=z+z; t=z+t; t=t+t;
            // t=t+t; z=z+t; x=x+z; z=x+x; z=z+z; y=y+z; z=y+y; z=z+z; z=z+z; z=y+z; x=x+z;
            // z=x+x; z=z+z; z=z+z; z=x+z; y=y+z; x=x+y; z=x+x; z=z+z; y=y+z; z=y+y; t=z+z;
            // t=t+t; t=t+t; z=z+t; x=x+z; y=y+x; z=y+y; z=z+z; z=z+z; x=x+z; z=x+x; z=z+z;
            // z=x+z; z=z+z; z=z+z; z=x+z; y=y+z; z=y+y; t=z+z; t=t+t; t=z+t; t=y+t; t=t+t;
            // t=t+t; t=t+t; t=t+t; z=z+t; x=x+z; z=x+x; z=x+z; y=y+z; z=y+y; z=y+z; z=z+z;
            // t=z+z; t=z+t; w=t+t; w=w+w; w=w+w; w=w+w; w=w+w; t=t+w; z=z+t; x=x+z; y=y+x;
            // z=y+y; x=x+z; y=y+x; x=x+y; y=y+x; x=x+y; z=x+x; z=x+z; z=z+z; y=y+z; z=y+y;
            // z=z+z; x=x+z; y=y+x; z=y+y; z=y+z; x=x+z; y=y+x; x=x+y; y=y+x; z=y+y; z=z+z;
            // z=y+z; x=x+z; z=x+x; z=x+z; y=y+z; x=x+y; y=y+x; x=x+y; y=y+x; z=y+y; z=y+z;
            // z=z+z; x=x+z; y=y+x; z=y+y; z=y+z; z=z+z; x=x+z; z=x+x; t=z+z; t=t+t; t=z+t;
            // t=x+t; t=t+t; t=t+t; t=t+t; t=t+t; z=z+t; y=y+z; x=x+y; y=y+x; x=x+y; z=x+x;
            // z=x+z; z=z+z; z=z+z; z=z+z; z=x+z; y=y+z; z=y+y; z=y+z; z=z+z; x=x+z; z=x+x;
            // z=x+z; y=y+z; x=x+y; z=x+x; z=z+z; y=y+z; x=x+y; z=x+x; y=y+z; x=x+y; y=y+x;
            // z=y+y; z=y+z; x=x+z; y=y+x; z=y+y; z=y+z; z=z+z; z=z+z; x=x+z; z=x+x; z=z+z;
            // z=z+z; z=x+z; y=y+z; x=x+y; z=x+x; t=x+z; t=t+t; t=t+t; z=z+t; y=y+z; z=y+y;
            // x=x+z; y=y+x; x=x+y; y=y+x; x=x+y; y=y+x; z=y+y; t=y+z; z=y+t; z=z+z; z=z+z;
            // z=t+z; x=x+z; y=y+x; x=x+y; y=y+x; x=x+y; z=x+x; z=x+z; y=y+z; x=x+y; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x; x=x+x;
            // x=x+x; x=x+x; x=x+x; x=x+x; res=y+x
            // res == (P + 1) // 4

            y := mulmod(x, x, p)
            {
                let z := mulmod(y, y, p)
                z := mulmod(z, z, p)
                y := mulmod(y, z, p)
                x := mulmod(x, y, p)
                y := mulmod(y, x, p)
                z := mulmod(y, y, p)
                {
                    let t := mulmod(z, z, p)
                    t := mulmod(z, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    z := mulmod(z, t, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(z, z, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(y, z, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    z := mulmod(x, x, p)
                    z := mulmod(z, z, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    t := mulmod(z, z, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    z := mulmod(z, t, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(z, z, p)
                    z := mulmod(x, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    t := mulmod(z, z, p)
                    t := mulmod(t, t, p)
                    t := mulmod(z, t, p)
                    t := mulmod(y, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    z := mulmod(z, t, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    z := mulmod(z, z, p)
                    t := mulmod(z, z, p)
                    t := mulmod(z, t, p)
                    {
                        let w := mulmod(t, t, p)
                        w := mulmod(w, w, p)
                        w := mulmod(w, w, p)
                        w := mulmod(w, w, p)
                        w := mulmod(w, w, p)
                        t := mulmod(t, w, p)
                    }
                    z := mulmod(z, t, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    z := mulmod(x, x, p)
                    z := mulmod(x, z, p)
                    z := mulmod(z, z, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    z := mulmod(z, z, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(z, z, p)
                    z := mulmod(y, z, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    z := mulmod(z, z, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    z := mulmod(z, z, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    t := mulmod(z, z, p)
                    t := mulmod(t, t, p)
                    t := mulmod(z, t, p)
                    t := mulmod(x, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    z := mulmod(z, t, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    z := mulmod(x, x, p)
                    z := mulmod(x, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    z := mulmod(z, z, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    z := mulmod(x, x, p)
                    z := mulmod(z, z, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    z := mulmod(x, x, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    z := mulmod(y, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    x := mulmod(x, z, p)
                    z := mulmod(x, x, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(x, z, p)
                    y := mulmod(y, z, p)
                    x := mulmod(x, y, p)
                    z := mulmod(x, x, p)
                    t := mulmod(x, z, p)
                    t := mulmod(t, t, p)
                    t := mulmod(t, t, p)
                    z := mulmod(z, t, p)
                    y := mulmod(y, z, p)
                    z := mulmod(y, y, p)
                    x := mulmod(x, z, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    x := mulmod(x, y, p)
                    y := mulmod(y, x, p)
                    z := mulmod(y, y, p)
                    t := mulmod(y, z, p)
                    z := mulmod(y, t, p)
                    z := mulmod(z, z, p)
                    z := mulmod(z, z, p)
                    z := mulmod(t, z, p)
                }
                x := mulmod(x, z, p)
                y := mulmod(y, x, p)
                x := mulmod(x, y, p)
                y := mulmod(y, x, p)
                x := mulmod(x, y, p)
                z := mulmod(x, x, p)
                z := mulmod(x, z, p)
                y := mulmod(y, z, p)
            }
            x := mulmod(x, y, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            x := mulmod(x, x, p)
            y := mulmod(y, x, p)
        }
    }
}
