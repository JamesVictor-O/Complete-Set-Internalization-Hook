// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockWrapped1155Factory} from "./mocks/MockWrapped1155Factory.sol";
import {CompleteSetInternalizationHook} from "../src/CompleteSetInternalizationHook.sol";
import {CompleteSetQuoter} from "../src/lens/CompleteSetQuoter.sol";
import {CompleteSetLib} from "../src/libraries/CompleteSetLib.sol";
import {ICompleteSetInternalizationHook} from "../src/interfaces/ICompleteSetInternalizationHook.sol";

contract CrossPoolInternalizationTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    MockConditionalTokens ctf;
    MockWrapped1155Factory factory;
    CompleteSetInternalizationHook hook;
    CompleteSetQuoter quoter;
    MockERC20 collateral;
    Currency yes;
    Currency no;
    PoolKey yesKey;
    PoolKey noKey;
    bytes32 conditionId;
    bytes32 marketId;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        deployArtifactsAndLabel();
        ctf = new MockConditionalTokens();
        factory = new MockWrapped1155Factory();
        address flags =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0xABCD << 144));
        deployCodeTo(
            "CompleteSetInternalizationHook.sol:CompleteSetInternalizationHook",
            abi.encode(poolManager, ctf, factory),
            flags
        );
        hook = CompleteSetInternalizationHook(flags);
        quoter = new CompleteSetQuoter(poolManager, hook);
        collateral = new MockERC20("Demo USD", "dUSD", 18);
        bytes32 question = keccak256("cross pool market");
        ctf.prepareCondition(address(0xFEED), question, 2);
        conditionId = CompleteSetLib.getConditionId(address(0xFEED), question, 2);
        IERC20 col = IERC20(address(collateral));
        yes = Currency.wrap(factory.requireWrapped1155(ctf, CompleteSetLib.yesPositionId(col, conditionId)));
        no = Currency.wrap(factory.requireWrapped1155(ctf, CompleteSetLib.noPositionId(col, conditionId)));
        yesKey = _key(yes);
        noKey = _key(no);
        marketId = hook.registerMarket(yesKey, noKey, col, conditionId, "YES", "YES", "NO", "NO");

        // Legitimate 80/20 probability state. Pool ratio is currency1/currency0, hence reciprocal when
        // dUSD sorts first. These prices are deliberately not treated as an invariant violation.
        poolManager.initialize(yesKey, _sqrtForOutcomePrice(yesKey, 2232)); // ~= 0.80
        poolManager.initialize(noKey, _sqrtForOutcomePrice(noKey, 16095)); // ~= 0.20
        _seed(yesKey, yes, 20 ether);
        _seed(noKey, no, 500 ether);

        collateral.mint(lp, 1_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(hook), type(uint256).max);
        hook.depositCollateral(marketId, 1_000 ether);
        vm.stopPrank();
        collateral.mint(trader, 1_000 ether);
        vm.startPrank(trader);
        collateral.approve(address(permit2), type(uint256).max);
        collateral.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(collateral), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function test_bothPoolsMapToSameConditionMarket() public view {
        ICompleteSetInternalizationHook.PoolBinding memory y = hook.poolBinding(yesKey.toId());
        ICompleteSetInternalizationHook.PoolBinding memory n = hook.poolBinding(noKey.toId());
        assertEq(y.marketId, marketId);
        assertEq(n.marketId, marketId);
        assertTrue(y.isYes);
        assertFalse(n.isYes);
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(marketId);
        assertEq(market.conditionId, conditionId);
    }

    function test_legitimateEightyTwentyPricesAreNotInvariantViolation() public view {
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, _buyDirection(yesKey), 0.01 ether);
        assertTrue(quote.ammQuote.available);
        assertFalse(quote.recommendSynthetic, "small executable edge does not clear fees and safety margin");
    }

    function test_thinYesPoolUsesExecutableComplementRoute() public {
        uint256 amount = 10 ether;
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, _buyDirection(yesKey), amount);
        assertTrue(quote.syntheticQuote.available);
        assertTrue(quote.recommendSynthetic);
        assertGt(quote.syntheticQuote.amount, quote.ammQuote.amount);

        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(amount, 0, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1);
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(marketId);
        assertGt(market.pendingCollateralClaims, 0);
        assertEq(market.yesInventory, 0);
        assertEq(market.noInventory, 0, "complement is atomically sold, not assigned fake NAV");
    }

    function test_outcomeSaleNeverUsesSyntheticBuyRoute() public view {
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, !_buyDirection(yesKey), 1 ether);
        assertFalse(quote.recommendSynthetic);
        assertFalse(quote.syntheticQuote.available);
    }

    function test_noPurchaseWithBetterDeepAmmRemainsOnAmm() public view {
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(noKey, _buyDirection(noKey), 1 ether);
        assertTrue(quote.ammQuote.available);
        assertFalse(quote.recommendSynthetic);
    }

    function test_noPurchaseUsesSyntheticRouteWhenNoAmmExecutionIsWorse() public {
        _buyOutcome(noKey, 300 ether);
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(noKey, _buyDirection(noKey), 10 ether);
        assertTrue(quote.syntheticQuote.available);
        assertTrue(quote.recommendSynthetic);

        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(10 ether, 0, _buyDirection(noKey), noKey, "", trader, block.timestamp + 1);
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(marketId);
        assertEq(market.yesInventory, 0);
        assertEq(market.noInventory, 0);
    }

    function test_thinComplementaryPoolMakesSyntheticRouteUnavailable() public view {
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(noKey, _buyDirection(noKey), 100 ether);
        assertTrue(quote.ammQuote.available);
        assertFalse(
            quote.syntheticQuote.available, "YES complement cannot execute the requested size in its active tick"
        );
        assertFalse(quote.recommendSynthetic);
    }

    function test_complementManipulationChangesExecutableQuoteButCannotFabricateReserveProfit() public {
        CompleteSetQuoter.QuoteResult memory beforeQuote = quoter.quote(yesKey, _buyDirection(yesKey), 5 ether);
        _buyOutcome(noKey, 100 ether);
        CompleteSetQuoter.QuoteResult memory afterQuote = quoter.quote(yesKey, _buyDirection(yesKey), 5 ether);
        assertTrue(afterQuote.syntheticQuote.available);
        assertNotEq(afterQuote.syntheticQuote.complementProceeds, beforeQuote.syntheticQuote.complementProceeds);

        if (afterQuote.recommendSynthetic) {
            uint256 reserveBefore = hook.getMarket(marketId).freeCollateral;
            vm.prank(trader);
            swapRouter.swapExactTokensForTokens(
                5 ether, 0, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1
            );
            hook.sweepCollateralClaims(marketId);
            assertEq(hook.getMarket(marketId).freeCollateral, reserveBefore);
        }
    }

    function test_repeatedAsymmetricFlowDoesNotAccumulateDirectionalInventory() public {
        for (uint256 i; i < 2; ++i) {
            CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, _buyDirection(yesKey), 2 ether);
            if (!quote.recommendSynthetic) break;
            vm.prank(trader);
            swapRouter.swapExactTokensForTokens(
                2 ether, 0, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1
            );
            hook.sweepCollateralClaims(marketId);
        }
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(marketId);
        assertEq(market.yesInventory, 0);
        assertEq(market.noInventory, 0, "synthetic fills atomically sell every complementary leg");
        assertEq(market.freeCollateral, 1_000 ether);
    }

    function test_exactOutputUsesCheaperSyntheticRoute() public {
        uint256 amountOut = 10 ether;
        CompleteSetQuoter.QuoteResult memory quote = quoter.quoteExactOutput(yesKey, _buyDirection(yesKey), amountOut);
        assertTrue(quote.recommendSynthetic);
        vm.prank(trader);
        swapRouter.swapTokensForExactTokens(
            amountOut, 100 ether, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1
        );
        assertGt(hook.getMarket(marketId).pendingCollateralClaims, 0);
    }

    function test_resolutionDisablesSyntheticRoutingButLeavesAmmAvailable() public {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        ctf.reportPayoutsForTest(conditionId, payouts);
        hook.freezeForResolution(marketId);
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, _buyDirection(yesKey), 10 ether);
        assertFalse(quote.recommendSynthetic);
        assertFalse(quote.syntheticQuote.available);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(
            0.01 ether, 0, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1
        );
        assertTrue(hook.getMarket(marketId).frozen);
    }

    function testFuzz_syntheticFillAndSweepNeverReduceReserve(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1 ether, 10 ether);
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, _buyDirection(yesKey), amount);
        if (!quote.recommendSynthetic) return;
        uint256 before = hook.getMarket(marketId).freeCollateral;
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(amount, 0, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1);
        hook.sweepCollateralClaims(marketId);
        assertEq(hook.getMarket(marketId).freeCollateral, before);
    }

    function test_insufficientReserveFallsBackToAmm() public {
        vm.prank(lp);
        hook.withdrawCollateral(marketId, 1_000 ether);
        CompleteSetQuoter.QuoteResult memory quote = quoter.quote(yesKey, _buyDirection(yesKey), 10 ether);
        assertFalse(quote.syntheticQuote.available);
        assertFalse(quote.recommendSynthetic);
    }

    function test_lpWithdrawalBlockedUntilClaimSettlement() public {
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(10 ether, 0, _buyDirection(yesKey), yesKey, "", trader, block.timestamp + 1);
        vm.expectRevert(ICompleteSetInternalizationHook.PendingSettlement.selector);
        vm.prank(lp);
        hook.withdrawCollateral(marketId, 1 ether);
        uint256 before = hook.getMarket(marketId).freeCollateral;
        hook.sweepCollateralClaims(marketId);
        assertGt(hook.getMarket(marketId).freeCollateral, before);
    }

    function test_cannotReusePoolForUnrelatedCondition() public {
        bytes32 otherQuestion = keccak256("unrelated");
        ctf.prepareCondition(address(0xFEED), otherQuestion, 2);
        bytes32 otherCondition = CompleteSetLib.getConditionId(address(0xFEED), otherQuestion, 2);
        vm.expectRevert();
        hook.registerMarket(yesKey, noKey, IERC20(address(collateral)), otherCondition, "Y", "Y", "N", "N");
    }

    function test_splitArbitrageCreditsOnlyRealizedCollateralProfit() public {
        vm.prank(lp);
        hook.withdrawCollateral(marketId, 1_000 ether);
        _buyOutcome(yesKey, 15 ether);
        _buyOutcome(noKey, 300 ether);
        collateral.mint(lp, 1_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(hook), 1_000 ether);
        hook.depositCollateral(marketId, 1_000 ether);
        vm.stopPrank();

        uint256 before = hook.getMarket(marketId).freeCollateral;
        uint256 surplus = hook.executeSplitArbitrage(marketId, 0.1 ether, 0);
        assertGt(surplus, 0);
        assertEq(hook.getMarket(marketId).freeCollateral, before + surplus);
        assertEq(hook.getMarket(marketId).lifetimeSurplus, surplus);
    }

    function test_mergeArbitrageCannotRunWithoutExecutableProfit() public {
        vm.expectRevert();
        hook.executeMergeArbitrage(marketId, 1 ether, type(uint256).max, 0);
    }

    function test_mergeArbitrageBuysBothOutcomesAndRealizesCollateral() public {
        _fundTraderOutcomes(100 ether);
        _sellOutcome(yesKey, yes, 5 ether);
        _sellOutcome(noKey, no, 50 ether);
        uint256 before = hook.getMarket(marketId).freeCollateral;
        uint256 surplus = hook.executeMergeArbitrage(marketId, 0.1 ether, 0.1 ether, 0);
        assertGt(surplus, 0);
        assertEq(hook.getMarket(marketId).freeCollateral, before + surplus);
        assertEq(hook.getMarket(marketId).lifetimeSurplus, surplus);
    }

    function test_smallDeviationBelowSafetyMarginDoesNotBookSurplus() public {
        uint256 before = hook.getMarket(marketId).freeCollateral;
        vm.expectRevert();
        hook.executeSplitArbitrage(marketId, 0.001 ether, 0);
        assertEq(hook.getMarket(marketId).freeCollateral, before);
        assertEq(hook.getMarket(marketId).lifetimeSurplus, 0);
    }

    function _buyOutcome(PoolKey memory key, uint256 amountIn) private {
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(amountIn, 0, _buyDirection(key), key, "", trader, block.timestamp + 1);
    }

    function _fundTraderOutcomes(uint256 amount) private {
        collateral.mint(trader, amount);
        vm.startPrank(trader);
        collateral.approve(address(ctf), amount);
        ctf.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );
        ctf.safeTransferFrom(
            trader,
            address(factory),
            CompleteSetLib.yesPositionId(IERC20(address(collateral)), conditionId),
            amount,
            CompleteSetLib.encodeWrappedTokenData(trader)
        );
        ctf.safeTransferFrom(
            trader,
            address(factory),
            CompleteSetLib.noPositionId(IERC20(address(collateral)), conditionId),
            amount,
            CompleteSetLib.encodeWrappedTokenData(trader)
        );
        IERC20(Currency.unwrap(yes)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(no)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(yes)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(no)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(yes), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(no), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _sellOutcome(PoolKey memory key, Currency outcome, uint256 amount) private {
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(amount, 0, key.currency0 == outcome, key, "", trader, block.timestamp + 1);
    }

    function _key(Currency outcome) private view returns (PoolKey memory) {
        Currency col = Currency.wrap(address(collateral));
        (Currency c0, Currency c1) = Currency.unwrap(col) < Currency.unwrap(outcome) ? (col, outcome) : (outcome, col);
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
    }

    function _buyDirection(PoolKey memory key) private view returns (bool) {
        return key.currency0 == Currency.wrap(address(collateral));
    }

    function _sqrtForOutcomePrice(PoolKey memory key, int24 absoluteTick) private view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(_buyDirection(key) ? absoluteTick : -absoluteTick);
    }

    function _seed(PoolKey memory key, Currency outcome, uint128 liquidity) private {
        address ammLp = makeAddr(string.concat("ammLp", vm.toString(uint256(PoolId.unwrap(key.toId())))));
        uint256 amount = uint256(liquidity) * 20;
        collateral.mint(ammLp, amount * 2);
        vm.startPrank(ammLp);
        collateral.approve(address(ctf), amount);
        ctf.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );
        uint256 positionId = outcome == yes
            ? CompleteSetLib.yesPositionId(IERC20(address(collateral)), conditionId)
            : CompleteSetLib.noPositionId(IERC20(address(collateral)), conditionId);
        ctf.safeTransferFrom(ammLp, address(factory), positionId, amount, CompleteSetLib.encodeWrappedTokenData(ammLp));
        collateral.approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(outcome)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(collateral), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(outcome), address(positionManager), type(uint160).max, type(uint48).max);
        positionManager.mint(
            key,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            liquidity,
            type(uint256).max,
            type(uint256).max,
            ammLp,
            block.timestamp + 1,
            ""
        );
        vm.stopPrank();
    }
}
