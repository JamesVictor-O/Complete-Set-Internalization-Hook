// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockWrapped1155Factory} from "./mocks/MockWrapped1155Factory.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {CompleteSetInternalizationHook} from "../src/CompleteSetInternalizationHook.sol";
import {ICompleteSetInternalizationHook} from "../src/interfaces/ICompleteSetInternalizationHook.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";
import {IWrapped1155Factory} from "../src/interfaces/IWrapped1155Factory.sol";
import {CompleteSetLib} from "../src/libraries/CompleteSetLib.sol";

/// @notice End-to-end tests for {CompleteSetInternalizationHook} against {MockConditionalTokens} and
/// {MockWrapped1155Factory} (see those files for why real Gnosis CTF/Wrapped1155Factory bytecode can't
/// be used directly here). Covers: hook permissions, market registration, the LP reserve/shares
/// accounting, the CTF-path NoOp fill and its inventory bookkeeping, automatic merge recycling (Key
/// Invariant #4 — no surplus from a purely symmetric round trip), and the freeze/redeem resolution path.
contract CompleteSetInternalizationHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    MockConditionalTokens conditionalTokens;
    MockWrapped1155Factory wrapped1155Factory;
    CompleteSetInternalizationHook hook;

    MockERC20 collateral;
    bytes32 conditionId;
    address constant ORACLE = address(0xFEED);
    bytes32 constant QUESTION_ID = keccak256("will it rain tomorrow");

    PoolKey poolKey;
    PoolId poolId;
    Currency yesCurrency;
    Currency noCurrency;
    bool yesIsCurrency0;

    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        deployArtifactsAndLabel();

        conditionalTokens = new MockConditionalTokens();
        wrapped1155Factory = new MockWrapped1155Factory();

        address flags =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x9999 << 144));
        bytes memory constructorArgs = abi.encode(poolManager, conditionalTokens, wrapped1155Factory);
        deployCodeTo("CompleteSetInternalizationHook.sol:CompleteSetInternalizationHook", constructorArgs, flags);
        hook = CompleteSetInternalizationHook(flags);

        collateral = new MockERC20("Collateral", "COL", 18);
        conditionalTokens.prepareCondition(ORACLE, QUESTION_ID, 2);
        conditionId = CompleteSetLib.getConditionId(ORACLE, QUESTION_ID, 2);

        // Pre-deploy the wrappers directly so the pool's currencies are known before `registerMarket`
        // is called — `registerMarket` will call `requireWrapped1155` again, idempotently, and verify
        // the PoolKey we build below actually matches these addresses.
        IERC20 collateralAsIERC20 = IERC20(address(collateral));
        uint256 yesPositionId = CompleteSetLib.yesPositionId(collateralAsIERC20, conditionId);
        uint256 noPositionId = CompleteSetLib.noPositionId(collateralAsIERC20, conditionId);
        address yesToken = wrapped1155Factory.requireWrapped1155(conditionalTokens, yesPositionId);
        address noToken = wrapped1155Factory.requireWrapped1155(conditionalTokens, noPositionId);

        yesIsCurrency0 = yesToken < noToken;
        (Currency currency0, Currency currency1) =
            yesIsCurrency0 ? (Currency.wrap(yesToken), Currency.wrap(noToken)) : (Currency.wrap(noToken), Currency.wrap(yesToken));
        yesCurrency = Currency.wrap(yesToken);
        noCurrency = Currency.wrap(noToken);

        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = poolKey.toId();

        hook.registerMarket(poolKey, collateralAsIERC20, conditionId, "YES", "YES", "NO", "NO");

        // Initialize at exactly 1:1 parity, with zero core liquidity: every exact-input swap in either
        // direction starts exactly on the CTF backstop's trigger boundary, and the hook fully absorbs it
        // (a pure NoOp swap needs no AMM liquidity at all).
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        collateral.mint(lp, 1_000 ether);
        vm.startPrank(lp);
        collateral.approve(address(hook), type(uint256).max);
        hook.depositCollateral(poolKey, 1_000 ether);
        vm.stopPrank();

        _approveTraderForSwapRouter(yesToken);
        _approveTraderForSwapRouter(noToken);
    }

    function _approveTraderForSwapRouter(address token) internal {
        vm.startPrank(trader);
        IERC20(token).approve(address(permit2), type(uint256).max);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        permit2.approve(token, address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev Trader bootstraps `amount` of the wrapped `leg` (YES if `wantYes`, else NO) by splitting
    /// fresh collateral through the mock CTF directly and wrapping the leg they want to trade with —
    /// exactly how a real user would source outcome tokens before this market has any AMM liquidity.
    function _giveTraderWrapped(bool wantYes, uint256 amount) internal returns (address token) {
        collateral.mint(trader, amount);
        vm.startPrank(trader);
        collateral.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            IERC20(address(collateral)), bytes32(0), conditionId, CompleteSetLib.binaryPartition(), amount
        );
        uint256 positionId = wantYes
            ? CompleteSetLib.yesPositionId(IERC20(address(collateral)), conditionId)
            : CompleteSetLib.noPositionId(IERC20(address(collateral)), conditionId);
        bytes memory wrapData = CompleteSetLib.encodeWrappedTokenData(trader);
        token = wantYes
            ? Currency.unwrap(yesCurrency)
            : Currency.unwrap(noCurrency);
        conditionalTokens.safeTransferFrom(trader, address(wrapped1155Factory), positionId, amount, wrapData);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------

    function test_getHookPermissions_onlyBeforeSwapAndReturnDelta() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap);
        assertTrue(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterSwapReturnDelta);
    }

    function test_registerMarket_wiresCurrenciesAndApproval() public view {
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertTrue(market.registered);
        assertEq(Currency.unwrap(market.yesCurrency), Currency.unwrap(yesCurrency));
        assertEq(Currency.unwrap(market.noCurrency), Currency.unwrap(noCurrency));
        assertEq(collateral.allowance(address(hook), address(conditionalTokens)), type(uint256).max);
    }

    function test_registerMarket_revertsIfAlreadyRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICompleteSetInternalizationHook.MarketAlreadyRegistered.selector, poolId)
        );
        hook.registerMarket(poolKey, IERC20(address(collateral)), conditionId, "YES", "YES", "NO", "NO");
    }

    function test_depositCollateral_firstDepositMintsSharesOneToOne() public view {
        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertEq(market.collateralReserve, 1_000 ether);
        assertEq(market.totalShares, 1_000 ether);
        assertEq(hook.sharesOf(poolId, lp), 1_000 ether);
    }

    function test_withdrawCollateral_returnsProportionalReserve() public {
        vm.prank(lp);
        uint256 amountOut = hook.withdrawCollateral(poolKey, 400 ether);
        assertEq(amountOut, 400 ether);
        assertEq(collateral.balanceOf(lp), 400 ether);

        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertEq(market.collateralReserve, 600 ether);
        assertEq(market.totalShares, 600 ether);
    }

    function test_swap_atParity_fillsFromCompleteSetWithZeroPoolManagerDelta() public {
        uint256 amount = 10 ether;
        address noToken = _giveTraderWrapped(false, amount); // trader holds NO, wants YES

        vm.prank(trader);
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: !yesIsCurrency0, // paying NO
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        // Trader paid exactly `amount` NO and received exactly `amount` YES — a pure 1:1 backstop fill,
        // not an AMM-curve price. Also implicitly proves Invariant #2: with zero core liquidity, the
        // only way this swap can succeed and net to a clean delta at all is if the hook's own take/settle
        // fully absorbed it, leaving nothing for PoolManager's own (empty) curve to fill.
        assertEq(IERC20(noToken).balanceOf(trader), 0);
        assertEq(IERC20(Currency.unwrap(yesCurrency)).balanceOf(trader), amount);
        int128 traderAmount0 = delta.amount0();
        int128 traderAmount1 = delta.amount1();
        if (yesIsCurrency0) {
            assertEq(traderAmount0, int128(int256(amount)));
            assertEq(traderAmount1, -int128(int256(amount)));
        } else {
            assertEq(traderAmount1, int128(int256(amount)));
            assertEq(traderAmount0, -int128(int256(amount)));
        }

        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertEq(market.collateralReserve, 1_000 ether - amount);
        assertEq(market.outstandingSplitCost, amount);
        // Paying NO: the split mints `amount` NO (byproduct, real inventory) and `amount` YES
        // (immediately wrapped away to the trader, netting to zero). The `amount` NO the trader paid in
        // is claimed (not yet real — see {CompleteSetInternalizationHook}'s NatSpec on claims vs real
        // tokens) until {sweepClaims}/{mergeIfPossible} converts it.
        assertEq(market.noInventory, amount);
        assertEq(market.noClaimBalance, amount);
        assertEq(market.yesInventory, 0);
        assertEq(market.yesClaimBalance, 0);
        assertEq(market.lifetimeSurplus, 0);
    }

    /// @notice Exact-output mirror of {test_swap_atParity_fillsFromCompleteSetWithZeroPoolManagerDelta}:
    /// the CTF fill is always 1:1 regardless of whether the trader's amount is specified as input or
    /// output, so the resulting balances/inventory are identical — only the swap call shape differs.
    function test_swap_exactOutput_atParity_fillsFromCompleteSetWithZeroPoolManagerDelta() public {
        uint256 amount = 10 ether;
        address noToken = _giveTraderWrapped(false, amount); // trader holds NO, wants exactly `amount` YES

        vm.prank(trader);
        BalanceDelta delta = swapRouter.swapTokensForExactTokens({
            amountOut: amount,
            amountInMax: amount,
            zeroForOne: !yesIsCurrency0, // paying NO
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        assertEq(IERC20(noToken).balanceOf(trader), 0);
        assertEq(IERC20(Currency.unwrap(yesCurrency)).balanceOf(trader), amount);
        int128 traderAmount0 = delta.amount0();
        int128 traderAmount1 = delta.amount1();
        if (yesIsCurrency0) {
            assertEq(traderAmount0, int128(int256(amount)));
            assertEq(traderAmount1, -int128(int256(amount)));
        } else {
            assertEq(traderAmount1, int128(int256(amount)));
            assertEq(traderAmount0, -int128(int256(amount)));
        }

        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertEq(market.collateralReserve, 1_000 ether - amount);
        assertEq(market.outstandingSplitCost, amount);
        assertEq(market.noInventory, amount);
        assertEq(market.noClaimBalance, amount);
        assertEq(market.yesInventory, 0);
        assertEq(market.yesClaimBalance, 0);
        assertEq(market.lifetimeSurplus, 0);
    }

    /// @notice Same invariant as {test_symmetricRoundTrip_autoMergesBackToStartingReserveWithZeroSurplus},
    /// but mixes an exact-input leg with an exact-output leg — proves the two code paths are truly
    /// equivalent 1:1 fills, not just individually correct.
    function test_symmetricRoundTrip_mixedExactInAndExactOut_autoMergesBackToStartingReserveWithZeroSurplus()
        public
    {
        uint256 amount = 10 ether;
        ICompleteSetInternalizationHook.Market memory before = hook.getMarket(poolId);

        _giveTraderWrapped(false, amount);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        _giveTraderWrapped(true, amount);
        vm.prank(trader);
        swapRouter.swapTokensForExactTokens({
            amountOut: amount,
            amountInMax: amount,
            zeroForOne: yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        hook.mergeIfPossible(poolKey);

        ICompleteSetInternalizationHook.Market memory afterTrades = hook.getMarket(poolId);
        assertEq(afterTrades.collateralReserve, before.collateralReserve);
        assertEq(afterTrades.outstandingSplitCost, 0);
        assertEq(afterTrades.yesInventory, 0);
        assertEq(afterTrades.noInventory, 0);
        assertEq(afterTrades.yesClaimBalance, 0);
        assertEq(afterTrades.noClaimBalance, 0);
        assertEq(afterTrades.lifetimeSurplus, 0);
    }

    // =========================================================================================
    // Fuzz tests on amount boundaries (bounded to `[1, market.collateralReserve]` — the CTF path's own
    // operating range; above that the hook falls back to the AMM curve by design, a separate code path
    // already covered by {test_swap_notProjectedToCrossParity_staysOnAmmCurve}).
    // =========================================================================================

    function testFuzz_swap_atParity_exactInput_fillsExactlyOneToOne(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);
        address noToken = _giveTraderWrapped(false, amount);

        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        assertEq(IERC20(noToken).balanceOf(trader), 0);
        assertEq(IERC20(Currency.unwrap(yesCurrency)).balanceOf(trader), amount);

        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertEq(market.collateralReserve, 1_000 ether - amount);
        assertEq(market.outstandingSplitCost, amount);
        assertEq(market.noInventory, amount);
        assertEq(market.noClaimBalance, amount);
        assertEq(market.yesInventory, 0);
        assertEq(market.lifetimeSurplus, 0);
    }

    function testFuzz_swap_atParity_exactOutput_fillsExactlyOneToOne(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);
        address noToken = _giveTraderWrapped(false, amount);

        vm.prank(trader);
        swapRouter.swapTokensForExactTokens({
            amountOut: amount,
            amountInMax: amount,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        assertEq(IERC20(noToken).balanceOf(trader), 0);
        assertEq(IERC20(Currency.unwrap(yesCurrency)).balanceOf(trader), amount);
        assertEq(hook.getMarket(poolId).collateralReserve, 1_000 ether - amount);
    }

    function testFuzz_depositCollateral_mintsSharesOneToOneAtStartingRatio(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        address newLp = makeAddr("newLp");
        collateral.mint(newLp, amount);

        vm.startPrank(newLp);
        collateral.approve(address(hook), amount);
        uint256 sharesMinted = hook.depositCollateral(poolKey, amount);
        vm.stopPrank();

        // setUp's initial LP deposit established an exact 1:1 collateral:share ratio, and no trade has
        // moved the reserve since, so every subsequent deposit at any amount must also mint 1:1.
        assertEq(sharesMinted, amount);
        assertEq(hook.sharesOf(poolId, newLp), amount);
        assertEq(hook.getMarket(poolId).collateralReserve, 1_000 ether + amount);
    }

    function testFuzz_withdrawCollateral_returnsExactlyProportionalReserve(uint256 shares) public {
        shares = bound(shares, 1, 1_000 ether); // lp holds exactly 1_000 ether shares from setUp
        vm.prank(lp);
        uint256 amountOut = hook.withdrawCollateral(poolKey, shares);

        // Still an exact 1:1 ratio (no trade has touched the reserve), so amountOut must equal shares.
        assertEq(amountOut, shares);
        assertEq(collateral.balanceOf(lp), shares);
        assertEq(hook.getMarket(poolId).collateralReserve, 1_000 ether - shares);
    }

    function testFuzz_withdrawCollateral_revertsAboveHeldShares(uint256 shares) public {
        shares = bound(shares, 1_000 ether + 1, type(uint128).max);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(ICompleteSetInternalizationHook.InsufficientShares.selector, shares, 1_000 ether)
        );
        hook.withdrawCollateral(poolKey, shares);
    }

    function testFuzz_symmetricRoundTrip_zeroSurplusAtAnyAmount(uint256 amount) public {
        // Bounded to half the reserve (not the full `[1, 1_000 ether]` CTF-path range used elsewhere):
        // each leg draws down the *same* shared reserve in sequence, so the second leg only stays fully
        // CTF-fillable (this test's whole premise) if `amount <= collateralReserve / 2`. Above that, the
        // second leg would legitimately fall through to the AMM curve instead (which has zero liquidity
        // in this fixture and reverts) — a fuzz-bound artifact of a two-leg test sharing one reserve, not
        // a hook defect.
        amount = bound(amount, 1, 500 ether);
        ICompleteSetInternalizationHook.Market memory before = hook.getMarket(poolId);

        _giveTraderWrapped(false, amount);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        _giveTraderWrapped(true, amount);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        hook.mergeIfPossible(poolKey);

        ICompleteSetInternalizationHook.Market memory afterTrades = hook.getMarket(poolId);
        assertEq(afterTrades.collateralReserve, before.collateralReserve);
        assertEq(afterTrades.outstandingSplitCost, 0);
        assertEq(afterTrades.yesInventory, 0);
        assertEq(afterTrades.noInventory, 0);
        assertEq(afterTrades.lifetimeSurplus, 0);
    }

    /// @dev Scoped to a low run count (via the forge-config comment below) — each run deploys a fresh
    /// liquid market plus a full-range AMM position, which is comparatively expensive to fuzz broadly.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_harvestOpportunisticSurplus_revertsAboveIdleBoundary(uint256 excess) public {
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_101_100);
        _payCurrency0(lm, 100 ether);
        lm.hook.sweepClaims(lm.key);

        ICompleteSetInternalizationHook.Market memory m = lm.hook.getMarket(lm.poolId);
        uint256 idle =
            m.yesInventory > m.noInventory ? m.yesInventory - m.noInventory : m.noInventory - m.yesInventory;

        excess = bound(excess, 1, 1_000_000 ether);
        uint256 amountIn = idle + excess;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICompleteSetInternalizationHook.InsufficientIdleInventory.selector, amountIn, idle
            )
        );
        lm.hook.harvestOpportunisticSurplus(lm.key, amountIn, 0);
    }

    function test_swap_revertsWhenMarketFrozen() public {
        _resolveAndFreeze();

        _giveTraderWrapped(false, 1 ether);
        vm.prank(trader);
        // The hook reverts with `MarketFrozen`, but v4-core's `Hooks.callHook` re-wraps any failed hook
        // call as `CustomRevert.WrappedError` before it reaches the caller — assert generically rather
        // than pinning the exact wrapped encoding, which is a v4-core implementation detail.
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });
    }

    /// @notice A round trip (NO->YES then YES->NO of the same size) leaves the hook's reserve exactly
    /// where it started and realizes zero surplus — the direct, executable version of the NatSpec claim
    /// that mechanism (A) is capital-neutral by construction (Key Invariant #4: no surplus from nowhere).
    function test_symmetricRoundTrip_autoMergesBackToStartingReserveWithZeroSurplus() public {
        uint256 amount = 10 ether;
        ICompleteSetInternalizationHook.Market memory before = hook.getMarket(poolId);

        _giveTraderWrapped(false, amount);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        _giveTraderWrapped(true, amount);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });

        // Merging only ever happens on an explicit, later call (see {CompleteSetInternalizationHook}'s
        // NatSpec on why claims can't be swept inside the same `beforeSwap` that created them).
        hook.mergeIfPossible(poolKey);

        ICompleteSetInternalizationHook.Market memory afterTrades = hook.getMarket(poolId);
        assertEq(afterTrades.collateralReserve, before.collateralReserve);
        assertEq(afterTrades.outstandingSplitCost, 0);
        assertEq(afterTrades.yesInventory, 0);
        assertEq(afterTrades.noInventory, 0);
        assertEq(afterTrades.yesClaimBalance, 0);
        assertEq(afterTrades.noClaimBalance, 0);
        assertEq(afterTrades.lifetimeSurplus, 0);
    }

    function test_freezeForResolution_revertsIfNotResolved() public {
        vm.expectRevert(abi.encodeWithSelector(ICompleteSetInternalizationHook.ConditionNotYetResolved.selector, conditionId));
        hook.freezeForResolution(poolKey);
    }

    function test_redeemAfterResolution_recoversRemainingInventoryAsCollateral() public {
        uint256 amount = 10 ether;
        _giveTraderWrapped(false, amount);
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: amount,
            zeroForOne: !yesIsCurrency0,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });
        // One-directional trade only: `amount` NO sits as real inventory (the split's byproduct) and
        // another `amount` NO sits as a claim (the trader's payment, not yet swept). Both must still be
        // fully recoverable after the market freezes — Invariant #3, no user/LP funds stuck.
        _resolveAndFreeze();

        (uint256 yesSwept, uint256 noSwept) = hook.sweepClaims(poolKey);
        assertEq(yesSwept, 0);
        assertEq(noSwept, amount);
        assertEq(hook.getMarket(poolId).noInventory, 2 * amount);

        uint256 reserveBeforeRedeem = hook.getMarket(poolId).collateralReserve;
        uint256 collateralReceived = hook.redeemAfterResolution(poolKey);

        ICompleteSetInternalizationHook.Market memory market = hook.getMarket(poolId);
        assertEq(market.yesClaimBalance, 0);
        assertEq(market.noClaimBalance, 0);
        assertEq(market.yesInventory, 0);
        assertEq(market.noInventory, 0);
        assertEq(market.collateralReserve, reserveBeforeRedeem + collateralReceived);
    }

    function _resolveAndFreeze() internal {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        conditionalTokens.reportPayoutsForTest(conditionId, payouts);
        hook.freezeForResolution(poolKey);
    }

    // =========================================================================================
    // Liquidity-bearing market fixture — used only by the trade-impact-aware parity tests and the
    // opportunistic-surplus-harvesting tests below, which (unlike every test above) need the pool to
    // have real core AMM liquidity and a resting price away from exact 1:1 parity. The main `setUp()`
    // fixture is deliberately initialized at exact parity with zero core liquidity (every exact-input
    // swap starts exactly on the CTF backstop's trigger boundary — see its own comment) which makes it
    // unusable for exercising "the pool is on the fair side of parity but a real AMM trade would move
    // it" scenarios; this fixture is a separate, self-contained market for exactly that purpose.
    // =========================================================================================

    /// @dev `_deployLiquidMarket`'s default `coreLiquidity` (500 ether) implies this LP reserve via the
    /// `10_000 ether + coreLiquidity * 4` formula there; kept as a named constant so tests asserting an
    /// exact `collateralReserve` don't hardcode a magic number that would silently drift out of sync.
    uint256 constant DEFAULT_LIQUID_LP_RESERVE = 10_000 ether + 500 ether * 4;

    struct LiquidMarket {
        CompleteSetInternalizationHook hook;
        PoolKey key;
        PoolId poolId;
        Currency yes;
        Currency no;
        bool yesIsCurrency0;
        bytes32 conditionId;
        uint256 yesPositionId;
        uint256 noPositionId;
        bytes yesWrapData;
        bytes noWrapData;
    }

    /// @dev Deploys a fresh hook + market + pool (distinct from `hook`/`poolKey`/`market` in `setUp()`),
    /// initialized at `initSqrtPriceX96`, funded with an LP collateral reserve, and given real core AMM
    /// liquidity via a full-range `positionManager` position (separate from the hook's own reserve).
    function _deployLiquidMarket(uint160 initSqrtPriceX96) internal returns (LiquidMarket memory lm) {
        return _deployLiquidMarket(initSqrtPriceX96, 500 ether);
    }

    function _deployLiquidMarket(uint160 initSqrtPriceX96, uint256 coreLiquidity)
        internal
        returns (LiquidMarket memory lm)
    {
        address flags =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0xAAAA << 144));
        bytes memory constructorArgs = abi.encode(poolManager, conditionalTokens, wrapped1155Factory);
        deployCodeTo("CompleteSetInternalizationHook.sol:CompleteSetInternalizationHook", constructorArgs, flags);
        lm.hook = CompleteSetInternalizationHook(flags);

        bytes32 questionId = keccak256(abi.encode("liquid market", initSqrtPriceX96, block.timestamp));
        conditionalTokens.prepareCondition(ORACLE, questionId, 2);
        lm.conditionId = CompleteSetLib.getConditionId(ORACLE, questionId, 2);

        IERC20 collateralAsIERC20 = IERC20(address(collateral));
        lm.yesPositionId = CompleteSetLib.yesPositionId(collateralAsIERC20, lm.conditionId);
        lm.noPositionId = CompleteSetLib.noPositionId(collateralAsIERC20, lm.conditionId);
        lm.yesWrapData = CompleteSetLib.encodeWrappedTokenData(address(lm.hook));
        lm.noWrapData = CompleteSetLib.encodeWrappedTokenData(address(lm.hook));
        address yesToken = wrapped1155Factory.requireWrapped1155(conditionalTokens, lm.yesPositionId);
        address noToken = wrapped1155Factory.requireWrapped1155(conditionalTokens, lm.noPositionId);

        lm.yesIsCurrency0 = yesToken < noToken;
        (Currency c0, Currency c1) = lm.yesIsCurrency0
            ? (Currency.wrap(yesToken), Currency.wrap(noToken))
            : (Currency.wrap(noToken), Currency.wrap(yesToken));
        lm.yes = Currency.wrap(yesToken);
        lm.no = Currency.wrap(noToken);
        lm.key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(lm.hook)});
        lm.poolId = lm.key.toId();

        lm.hook.registerMarket(lm.key, collateralAsIERC20, lm.conditionId, "LYES", "LYES", "LNO", "LNO");
        poolManager.initialize(lm.key, initSqrtPriceX96);

        uint256 lpReserve = 10_000 ether + coreLiquidity * 4;
        collateral.mint(lp, lpReserve);
        vm.startPrank(lp);
        collateral.approve(address(lm.hook), type(uint256).max);
        lm.hook.depositCollateral(lm.key, lpReserve);
        vm.stopPrank();

        _seedCoreLiquidity(lm, coreLiquidity);
    }

    /// @dev Funds a fresh LP with real wrapped YES/NO (sourced directly from the CTF, exactly as a real
    /// liquidity provider would) and mints a full-range `positionManager` position — genuine Uniswap
    /// curve depth, entirely separate from the hook's own collateral reserve.
    function _seedCoreLiquidity(LiquidMarket memory lm, uint256 coreLiquidity) internal {
        address ammLp = makeAddr("ammLp");
        uint256 wrapAmount = coreLiquidity * 20;
        _mintWrapped(lm.conditionId, lm.yesPositionId, lm.yesWrapData, ammLp, wrapAmount);
        _mintWrapped(lm.conditionId, lm.noPositionId, lm.noWrapData, ammLp, wrapAmount);

        vm.startPrank(ammLp);
        IERC20(Currency.unwrap(lm.yes)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(lm.no)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(lm.yes), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(lm.no), address(positionManager), type(uint160).max, type(uint48).max);

        positionManager.mint(
            lm.key,
            TickMath.minUsableTick(lm.key.tickSpacing),
            TickMath.maxUsableTick(lm.key.tickSpacing),
            coreLiquidity,
            type(uint256).max,
            type(uint256).max,
            ammLp,
            block.timestamp + 1,
            ""
        );
        vm.stopPrank();
    }

    /// @dev Mints `amount` of `collateral` to `to`, splits it into a full complete set through the real
    /// CTF, and wraps+sends the `positionId` leg to `to`, leaving `to` holding `amount` of that leg as a
    /// real wrapped ERC-20 (the other, unwrapped leg is left as an unused raw-CTF byproduct in `to`'s
    /// account — harmless in tests). Generalizes {_giveTraderWrapped} to an arbitrary market/recipient.
    function _mintWrapped(bytes32 cid, uint256 positionId, bytes memory wrapData, address to, uint256 amount)
        internal
    {
        collateral.mint(to, amount);
        vm.startPrank(to);
        collateral.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            IERC20(address(collateral)), bytes32(0), cid, CompleteSetLib.binaryPartition(), amount
        );
        conditionalTokens.safeTransferFrom(
            to, address(wrapped1155Factory), positionId, amount, CompleteSetLib.encodeWrappedTokenData(to)
        );
        vm.stopPrank();
    }

    /// @dev Runs one exact-input CTF-backstop fill in `lm`'s market where `trader` pays currency0 and
    /// receives currency1 — used both to seed a predictable idle inventory imbalance for the harvest
    /// tests and, when sized large enough relative to `lm`'s liquidity, to exercise the trade-impact-
    /// aware parity check itself.
    function _payCurrency0(LiquidMarket memory lm, uint256 amount) internal {
        bool payYes = lm.yesIsCurrency0;
        _mintWrapped(
            lm.conditionId, payYes ? lm.yesPositionId : lm.noPositionId, payYes ? lm.yesWrapData : lm.noWrapData, trader, amount
        );
        address payToken = payYes ? Currency.unwrap(lm.yes) : Currency.unwrap(lm.no);
        vm.startPrank(trader);
        IERC20(payToken).approve(address(permit2), type(uint256).max);
        IERC20(payToken).approve(address(swapRouter), type(uint256).max);
        permit2.approve(payToken, address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.prank(trader);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: lm.key,
            hookData: bytes(""),
            receiver: trader,
            deadline: block.timestamp + 1
        });
    }

    /// @notice With real core liquidity resting 1% above parity, a trade whose own size (projected
    /// against that liquidity) would walk the price down at or past parity must be fully CTF-filled,
    /// even though the pool's *current* spot price alone is on the fair side of parity and the old
    /// spot-only check would have let it hit the AMM curve instead.
    function test_swap_projectedToCrossParity_fillsFullyFromCompleteSet() public {
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_101_100);

        uint256 amount = 100 ether; // large relative to the 500 ether of core liquidity seeded
        _payCurrency0(lm, amount);

        // A pure CTF fill is exact 1:1 and leaves the paid-in leg as real inventory + a pending claim;
        // an AMM-curve fill would not produce this exact bookkeeping (and would not be exactly 1:1).
        ICompleteSetInternalizationHook.Market memory market = lm.hook.getMarket(lm.poolId);
        assertEq(market.collateralReserve, DEFAULT_LIQUID_LP_RESERVE - amount);
        assertEq(market.outstandingSplitCost, amount);
        bool payYes = lm.yesIsCurrency0;
        assertEq(payYes ? market.yesInventory : market.noInventory, amount);
        assertEq(payYes ? market.yesClaimBalance : market.noClaimBalance, amount);
        assertEq(payYes ? market.noInventory : market.yesInventory, 0);
    }

    /// @notice Control for the test above: a trade small enough that its own price impact stays clear
    /// of parity is left to the AMM curve, exactly as before — the trade-impact check only ever adds
    /// coverage, it does not newly intercept trades that were never going to reach parity.
    function test_swap_notProjectedToCrossParity_staysOnAmmCurve() public {
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_101_100);

        uint256 amount = 0.01 ether; // tiny relative to the 500 ether of core liquidity seeded
        _payCurrency0(lm, amount);

        ICompleteSetInternalizationHook.Market memory market = lm.hook.getMarket(lm.poolId);
        assertEq(market.collateralReserve, DEFAULT_LIQUID_LP_RESERVE, "reserve must be untouched by an AMM-curve fill");
        assertEq(market.outstandingSplitCost, 0);
        assertEq(market.yesInventory, 0);
        assertEq(market.noInventory, 0);
    }

    /// @notice Key Invariant #4, mechanism B: harvesting idle inventory against a favorably-priced AMM
    /// curve realizes real, positive `lifetimeSurplus` — the hard no-lose floor still allows genuinely
    /// profitable trades through.
    function test_harvestOpportunisticSurplus_sellsIdleLegAndMergesSurplus() public {
        // A large starting price divergence (2:1, vs. the ~1% used by the parity tests above) is used
        // deliberately here: whatever a single seed fill leaves in `outstandingSplitCost` must be repaid
        // out of ordinary ($1/unit) merge proceeds before any of a *subsequent* profitable trade's edge
        // shows up as `lifetimeSurplus` (Key Invariant #4 — no surplus credited beyond what a real merge
        // actually recovers). A deep, obviously-favorable curve keeps that edge comfortably larger than
        // the seed's own cost so the test isn't chasing a razor-thin breakeven amount.
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_2_1, 5_000 ether);

        // Seed an idle imbalance on the currency0 side (the richer side at a 2:1 price) via a large,
        // guaranteed CTF fill — see {test_swap_projectedToCrossParity_fillsFullyFromCompleteSet}.
        uint256 seedAmount = 2_000 ether;
        _payCurrency0(lm, seedAmount);
        lm.hook.sweepClaims(lm.key);

        ICompleteSetInternalizationHook.Market memory before = lm.hook.getMarket(lm.poolId);
        uint256 idleBefore =
            before.yesInventory > before.noInventory ? before.yesInventory - before.noInventory : before.noInventory - before.yesInventory;
        assertEq(idleBefore, 2 * seedAmount);

        // Must be large enough that the resulting merged amount exceeds the seed's own
        // `outstandingSplitCost` (else the merge's proceeds are entirely absorbed repaying that
        // pre-existing, ordinary $1/unit cost before any of *this* trade's favorable-price edge can
        // show up as surplus — see the comment above), while staying under `idleBefore`.
        uint256 harvestAmount = (seedAmount * 9) / 10;
        (uint256 amountMerged, uint256 surplus) = lm.hook.harvestOpportunisticSurplus(lm.key, harvestAmount, 0);

        assertGt(amountMerged, 0);
        assertGt(surplus, 0);
        ICompleteSetInternalizationHook.Market memory afterHarvest = lm.hook.getMarket(lm.poolId);
        assertEq(afterHarvest.lifetimeSurplus, surplus);
    }

    function test_harvestOpportunisticSurplus_revertsWithNoIdleInventory() public {
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_101_100);

        vm.expectRevert(
            abi.encodeWithSelector(ICompleteSetInternalizationHook.InsufficientIdleInventory.selector, 1 ether, 0)
        );
        lm.hook.harvestOpportunisticSurplus(lm.key, 1 ether, 0);
    }

    function test_harvestOpportunisticSurplus_revertsIfMarketFrozen() public {
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_101_100);
        _payCurrency0(lm, 100 ether);
        lm.hook.sweepClaims(lm.key);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        conditionalTokens.reportPayoutsForTest(lm.conditionId, payouts);
        lm.hook.freezeForResolution(lm.key);

        vm.expectRevert(abi.encodeWithSelector(ICompleteSetInternalizationHook.MarketFrozen.selector, lm.poolId));
        lm.hook.harvestOpportunisticSurplus(lm.key, 1 ether, 0);
    }

    /// @notice The hard no-lose floor is enforced by the contract itself, not merely by the caller's
    /// `minAmountOut`: selling deep enough into the curve that price impact would make the trade
    /// unprofitable reverts, even though the caller only asked for `minAmountOut = 0`.
    function test_harvestOpportunisticSurplus_revertsOnUnprofitableSlippageFloor() public {
        LiquidMarket memory lm = _deployLiquidMarket(Constants.SQRT_PRICE_101_100);

        _payCurrency0(lm, 100 ether);
        lm.hook.sweepClaims(lm.key);

        // Selling a large fraction of the 200 ether idle imbalance into only 500 ether of core liquidity
        // that starts just 1% above parity walks the price well past parity — the average execution
        // price ends up below 1:1, which must revert rather than silently losing value.
        vm.expectRevert(); // exact amounts are curve-dependent; only the outcome (revert) is asserted
        lm.hook.harvestOpportunisticSurplus(lm.key, 100 ether, 0);
    }
}
