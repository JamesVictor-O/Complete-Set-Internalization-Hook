// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockWrapped1155Factory} from "./mocks/MockWrapped1155Factory.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {CompleteSetInternalizationHook} from "../src/CompleteSetInternalizationHook.sol";
import {CompleteSetQuoter} from "../src/lens/CompleteSetQuoter.sol";
import {ICompleteSetInternalizationHook} from "../src/interfaces/ICompleteSetInternalizationHook.sol";
import {CompleteSetLib} from "../src/libraries/CompleteSetLib.sol";

/// @notice Unit tests for {CompleteSetQuoter} — the standalone "quote comparison logic" CLAUDE.md's
/// testing requirements call for, which the hook itself never exposed as a separate callable unit.
contract CompleteSetQuoterTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    MockConditionalTokens conditionalTokens;
    MockWrapped1155Factory wrapped1155Factory;
    CompleteSetInternalizationHook hook;
    CompleteSetQuoter quoter;

    MockERC20 collateral;
    bytes32 conditionId;
    address constant ORACLE = address(0xFEED);
    bytes32 constant QUESTION_ID = keccak256("quoter test question");

    PoolKey poolKey;
    PoolId poolId;
    Currency yesCurrency;
    Currency noCurrency;
    bool yesIsCurrency0;

    address lp = makeAddr("lp");

    function setUp() public {
        deployArtifactsAndLabel();

        conditionalTokens = new MockConditionalTokens();
        wrapped1155Factory = new MockWrapped1155Factory();

        address flags =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0xBEEF << 144));
        bytes memory constructorArgs = abi.encode(poolManager, conditionalTokens, wrapped1155Factory);
        deployCodeTo("CompleteSetInternalizationHook.sol:CompleteSetInternalizationHook", constructorArgs, flags);
        hook = CompleteSetInternalizationHook(flags);
        quoter = new CompleteSetQuoter(poolManager, hook);

        collateral = new MockERC20("Collateral", "COL", 18);
        conditionalTokens.prepareCondition(ORACLE, QUESTION_ID, 2);
        conditionId = CompleteSetLib.getConditionId(ORACLE, QUESTION_ID, 2);

        IERC20 collateralAsIERC20 = IERC20(address(collateral));
        uint256 yesPositionId = CompleteSetLib.yesPositionId(collateralAsIERC20, conditionId);
        uint256 noPositionId = CompleteSetLib.noPositionId(collateralAsIERC20, conditionId);
        address yesToken = wrapped1155Factory.requireWrapped1155(
            conditionalTokens, yesPositionId, CompleteSetLib.encodeWrappedTokenData("YES", "YES", 18)
        );
        address noToken = wrapped1155Factory.requireWrapped1155(
            conditionalTokens, noPositionId, CompleteSetLib.encodeWrappedTokenData("NO", "NO", 18)
        );

        yesIsCurrency0 = yesToken < noToken;
        (Currency currency0, Currency currency1) = yesIsCurrency0
            ? (Currency.wrap(yesToken), Currency.wrap(noToken))
            : (Currency.wrap(noToken), Currency.wrap(yesToken));
        yesCurrency = Currency.wrap(yesToken);
        noCurrency = Currency.wrap(noToken);

        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = poolKey.toId();

        hook.registerMarket(poolKey, collateralAsIERC20, conditionId, "YES", "YES", "NO", "NO");
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        collateral.mint(lp, 1_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(hook), type(uint256).max);
        hook.depositCollateral(poolKey, 1_000 ether);
        vm.stopPrank();
    }

    /// @notice With zero core liquidity and the pool exactly at parity, the AMM leg can't fill at all
    /// and the CTF leg is exactly 1:1 — the same starting state `CompleteSetInternalizationHookTest`'s
    /// zero-liquidity fixture uses, so the recommendation must be CTF, matching every swap test there.
    function test_quote_zeroLiquidity_ammUnavailableCtfRecommended() public view {
        CompleteSetQuoter.QuoteResult memory result = quoter.quote(poolKey, !yesIsCurrency0, 10 ether);

        assertFalse(result.ammQuote.available);
        assertEq(result.ammQuote.outAmount, 0);

        assertTrue(result.ctfQuote.available);
        assertEq(result.ctfQuote.outAmount, 10 ether);
        assertEq(result.ctfQuote.effectivePriceWad, 1e18);
        assertEq(result.ctfQuote.priceImpactBps, 0);

        assertTrue(result.recommendCtf);
    }

    function test_quote_ctfUnavailable_whenAmountExceedsReserve() public view {
        CompleteSetQuoter.QuoteResult memory result = quoter.quote(poolKey, !yesIsCurrency0, 2_000 ether);
        assertFalse(result.ctfQuote.available);
        assertFalse(result.recommendCtf);
    }

    function test_quote_zeroAmountIn_returnsEmptyUnavailableQuotes() public view {
        CompleteSetQuoter.QuoteResult memory result = quoter.quote(poolKey, !yesIsCurrency0, 0);
        assertFalse(result.ammQuote.available);
        assertFalse(result.ctfQuote.available);
        assertFalse(result.recommendCtf);
    }

    /// @notice With real core AMM liquidity resting off parity, the AMM quote must show a genuinely
    /// worse (non-1:1) price with nonzero impact, while the CTF quote stays exactly 1:1 — and the
    /// recommendation must match {CompleteSetLib-priceIsAtOrPastParity} exactly, since `quote` calls
    /// that same function directly. Builds its own separate market (fresh condition, fresh pool)
    /// initialized off-parity, since `setUp()`'s shared pool is already initialized at parity.
    function test_quote_liquidMarket_ammShowsRealImpactCtfStaysFair() public {
        bytes32 liquidQuestionId = keccak256("quoter liquidity test question");
        conditionalTokens.prepareCondition(ORACLE, liquidQuestionId, 2);
        bytes32 liquidConditionId = CompleteSetLib.getConditionId(ORACLE, liquidQuestionId, 2);

        IERC20 collateralAsIERC20 = IERC20(address(collateral));
        uint256 yesPositionId = CompleteSetLib.yesPositionId(collateralAsIERC20, liquidConditionId);
        uint256 noPositionId = CompleteSetLib.noPositionId(collateralAsIERC20, liquidConditionId);
        address liquidYesToken = wrapped1155Factory.requireWrapped1155(
            conditionalTokens, yesPositionId, CompleteSetLib.encodeWrappedTokenData("LYES", "LYES", 18)
        );
        address liquidNoToken = wrapped1155Factory.requireWrapped1155(
            conditionalTokens, noPositionId, CompleteSetLib.encodeWrappedTokenData("LNO", "LNO", 18)
        );
        bool liquidYesIsCurrency0 = liquidYesToken < liquidNoToken;
        (Currency c0, Currency c1) = liquidYesIsCurrency0
            ? (Currency.wrap(liquidYesToken), Currency.wrap(liquidNoToken))
            : (Currency.wrap(liquidNoToken), Currency.wrap(liquidYesToken));
        PoolKey memory liquidKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

        hook.registerMarket(liquidKey, collateralAsIERC20, liquidConditionId, "LYES", "LYES", "LNO", "LNO");
        poolManager.initialize(liquidKey, Constants.SQRT_PRICE_101_100);

        collateral.mint(lp, 1_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(hook), 1_000 ether);
        hook.depositCollateral(liquidKey, 1_000 ether);
        vm.stopPrank();

        // Seed a full-range position priced 1% above parity, mirroring the pattern in
        // CompleteSetInternalizationHookTest's `_deployLiquidMarket`/`_seedCoreLiquidity`.
        address ammLp = makeAddr("ammLp");
        uint256 wrapAmount = 10_000 ether;
        _mintWrapped(liquidConditionId, yesPositionId, "LYES", ammLp, wrapAmount);
        _mintWrapped(liquidConditionId, noPositionId, "LNO", ammLp, wrapAmount);

        vm.startPrank(ammLp);
        IERC20(liquidYesToken).approve(address(permit2), type(uint256).max);
        IERC20(liquidNoToken).approve(address(permit2), type(uint256).max);
        permit2.approve(liquidYesToken, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(liquidNoToken, address(positionManager), type(uint160).max, type(uint48).max);
        positionManager.mint(
            liquidKey,
            TickMath.minUsableTick(liquidKey.tickSpacing),
            TickMath.maxUsableTick(liquidKey.tickSpacing),
            500 ether,
            type(uint256).max,
            type(uint256).max,
            ammLp,
            block.timestamp + 1,
            ""
        );
        vm.stopPrank();

        // A small trade paying currency1 (the cheaper side at a >1 price, in currency1-per-currency0
        // terms) gets *less* than 1:1 on the AMM curve, while the CTF backstop still offers exactly
        // 1:1 - so CTF must be recommended. (Paying the pricier currency0 side would net *more* than
        // 1:1 on the curve instead - not the scenario this test is proving.)
        uint256 amount = 1 ether;
        CompleteSetQuoter.QuoteResult memory result = quoter.quote(liquidKey, false, amount);

        assertTrue(result.ammQuote.available);
        assertLt(result.ammQuote.outAmount, amount, "paying the cheaper side must yield less than 1:1 on the curve");
        assertGt(result.ammQuote.priceImpactBps, 0);

        assertTrue(result.ctfQuote.available);
        assertEq(result.ctfQuote.outAmount, amount);
        assertEq(result.ctfQuote.priceImpactBps, 0);

        assertTrue(result.recommendCtf, "CTF is strictly better here and must be recommended");
    }

    function _mintWrapped(bytes32 forConditionId, uint256 positionId, string memory symbol, address to, uint256 amount)
        internal
    {
        collateral.mint(to, amount);
        vm.startPrank(to);
        collateral.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            IERC20(address(collateral)), bytes32(0), forConditionId, CompleteSetLib.binaryPartition(), amount
        );
        bytes memory wrapData = CompleteSetLib.encodeWrappedTokenData(symbol, symbol, 18);
        conditionalTokens.safeTransferFrom(to, address(wrapped1155Factory), positionId, amount, wrapData);
        vm.stopPrank();
    }
}
