# Complete-Set Internalization Hook — four-minute demo

> Record only after deploying the new two-pool architecture. The previous Unichain deployment is obsolete.

## 0:00–0:40 — What the hook does

“Hello everyone, my name is James Victor, and I built the Complete-Set Internalization Hook for the Atrium Uniswap Hook Incubator.

In a binary CTF market, one dUSD can split into one YES plus one NO, and that pair can merge back into one dUSD. This does not mean YES equals NO. A valid market can price YES at eighty cents and NO at twenty cents.

The problem I am solving is execution under price impact. When a direct outcome pool becomes expensive, the complementary market may reveal a cheaper way to source that outcome through the complete-set transformation.”

## 0:40–1:15 — Show the two pools

**Show:** Switch between **YES/dUSD** and **NO/dUSD**.

“One CTF condition maps to two Uniswap v4 pools. Both outcomes have direct collateral-denominated price discovery. The hook knows they are complements because registration derives both wrapped tokens from the same collateral and condition.

The dashboard keeps Uniswap active liquidity separate from the hook’s free collateral reserve. Those are different sources of liquidity.”

## 1:15–2:20 — Compare and execute routes

**Show:** Select YES, enter a small dUSD amount, then a larger amount that recommends the complete-set route.

“For every requested size, the quoter compares real executable outcomes.

The first route is the normal YES/dUSD AMM. The second route starts by splitting dUSD into YES and NO. The YES is available for my purchase, while the newly created NO is sold into the NO/dUSD pool. If that NO sale returns thirty cents, the effective cost of YES is roughly one dollar minus thirty cents—not one dollar, and not one NO.

For exact input, the hook can also recycle those complementary-sale proceeds through the YES pool. It chooses the synthetic route only when total output beats the normal AMM after fees and a thirty-basis-point safety margin.

I click Swap once. Approval appears first if needed, then the swap confirmation opens automatically.”

**Show:** Confirm and highlight the updated outcome balance and pending settlement.

## 2:20–2:55 — Explain reserve settlement

“The reserve provides the real dUSD needed for the atomic CTF split. The trader’s net dUSD payment initially arrives as a PoolManager claim because final router settlement happens after the hook callback.

I settle that claim, and the reserve returns to its starting basis. The hook does not pretend unmatched outcomes are collateral profit. The complementary token was sold during the same execution, so normal fills end with no directional inventory.”

**Show:** Click **Settle dUSD claim** and show restored free collateral.

## 2:55–3:35 — Show the code

**Show:** `CompleteSetInternalizationHook._beforeSwap`, `_quoteExactInput`, then `CrossPoolExecutionLib.splitAndExecuteSynthetic`.

“Here, `beforeSwap` resolves whether the invocation belongs to the YES or NO pool. The quote functions compare direct and synthetic executable amounts for the actual size.

The execution library performs the split and complementary-pool sale atomically. The nested swap does not recursively call the hook because the hook itself is the nested caller. Minimum proceeds, reserve availability, and the safety margin protect the reserve; if the complementary pool is too thin, execution stays on the normal AMM.”

## 3:35–4:00 — Arbitrage, tests, close

**Show:** Test output, focusing on the 80/20, thin-pool, manipulation, split/merge, and fuzz cases.

“The same executable logic supports complete-set arbitrage. If selling both newly split legs returns more than their collateral basis, the hook can split and sell. If buying both legs costs less than one dUSD, it can merge them. Only realized collateral above basis is surplus.

So this hook does not constrain prediction probabilities. It uses the true CTF invariant to provide better execution when a complete-set transformation is economically superior. Thank you.”
