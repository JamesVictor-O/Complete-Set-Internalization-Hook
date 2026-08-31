# Complete-Set Internalization Hook

**A Uniswap v4 hook that turns the Gnosis Conditional Tokens Framework (CTF) complete-set
invariant — `1 YES + 1 NO = exactly 1 unit of collateral` — into a native liquidity source
and a hard price-impact backstop for binary-outcome (YES/NO) pools.**

Submitted as a graduation project for the Uniswap Hook Incubator (UHI), hosted by Atrium —
Sustainable Liquidity & MEV Protection track.

> **Live on Unichain Sepolia:**
> [`CompleteSetInternalizationHook — 0xc88B0aC546a99B586199dDBeE30D801Ee1d80088`](https://sepolia.uniscan.xyz/address/0xc88B0aC546a99B586199dDBeE30D801Ee1d80088)
> · [deployment transaction](https://sepolia.uniscan.xyz/tx/0x1a9052149599281a934f1df96205a5d3ed9eb10aec14b2a135a83d5b71130623)
> · [full deployment details](#live-deployment--unichain-sepolia)

## Reviewer's guide — where everything is implemented

New to this repo? Start here. Every row below is a specific, checkable claim — the file and
line is where to go read the actual code, not take this table's word for it. `forge test -vv`
(see [Development](#development)) reproduces every one of them live.

| Claim | Where to look | What you'll find |
|---|---|---|
| The core mechanism: fill trades via CTF at 1:1 instead of the AMM curve | [`_beforeSwap`, `src/CompleteSetInternalizationHook.sol:184`](src/CompleteSetInternalizationHook.sol#L184) | The whole swap-routing decision, in one function |
| Hook only touches `beforeSwap` / `beforeSwapReturnDelta` — minimal permission surface | [`getHookPermissions`, `src/CompleteSetInternalizationHook.sol:93`](src/CompleteSetInternalizationHook.sol#L93) | Verified by [`test_getHookPermissions_...`, `test/CompleteSetInternalizationHook.t.sol:144`](test/CompleteSetInternalizationHook.t.sol#L144) |
| Trade-impact-aware parity check (projects the *trade's own* price impact via the pool's tick liquidity, not just current spot price) | [`priceIsAtOrPastParity`, `src/libraries/CompleteSetLib.sol:273`](src/libraries/CompleteSetLib.sol#L273) | Proven by two paired tests: a trade sized to cross parity gets fully CTF-filled ([`test/CompleteSetInternalizationHook.t.sol:744`](test/CompleteSetInternalizationHook.t.sol#L744)) while a small one that never would is left on the AMM curve ([`:764`](test/CompleteSetInternalizationHook.t.sol#L764)) |
| Pure NoOp delta — `PoolManager`'s own curve is provably untouched when the CTF path fires | Return value of `_beforeSwap`, [`src/CompleteSetInternalizationHook.sol:184-226`](src/CompleteSetInternalizationHook.sol#L184) | [`test_swap_atParity_...`, `:187`](test/CompleteSetInternalizationHook.t.sol#L187) asserts the *exact* `BalanceDelta` the `PoolManager` sees, for both exact-input and exact-output ([`:235`](test/CompleteSetInternalizationHook.t.sol#L235)) |
| Market registration (binds one pool to one CTF condition, self-verifying) | [`registerMarket`, `src/CompleteSetInternalizationHook.sol:117`](src/CompleteSetInternalizationHook.sol#L117) → [`CompleteSetLib.sol:167`](src/libraries/CompleteSetLib.sol#L167) | [`test_registerMarket_...`, `:154`](test/CompleteSetInternalizationHook.t.sol#L154) |
| LP collateral reserve, share-based NAV | [`depositCollateral` / `withdrawCollateral`, `src/CompleteSetInternalizationHook.sol:145` / `:161`](src/CompleteSetInternalizationHook.sol#L145) | [`:169`](test/CompleteSetInternalizationHook.t.sol#L169), [`:176`](test/CompleteSetInternalizationHook.t.sol#L176), plus fuzzed at [`:370`](test/CompleteSetInternalizationHook.t.sol#L370) |
| Complete-set merge + surplus accounting (surplus only from real recovered proceeds, never fabricated) | [`mergeIfPossible`, `src/libraries/CompleteSetLib.sol:300`](src/libraries/CompleteSetLib.sol#L300) — see the `recoveredCost`/`surplus` formula at [`:315-317`](src/libraries/CompleteSetLib.sol#L315) | A symmetric round trip nets exactly zero surplus: [`:497`](test/CompleteSetInternalizationHook.t.sol#L497), fuzzed at [`:407`](test/CompleteSetInternalizationHook.t.sol#L407) |
| **Mechanism B** — opportunistic surplus harvesting: sell idle YES/NO inventory into the pool's *own* curve, hard on-chain no-lose floor | [`harvestOpportunisticSurplus`, `src/CompleteSetInternalizationHook.sol:249`](src/CompleteSetInternalizationHook.sol#L249) → [`sellIdleLegOnCurve`, `CompleteSetLib.sol:331`](src/libraries/CompleteSetLib.sol#L331) | Realizes real, positive surplus: [`:780`](test/CompleteSetInternalizationHook.t.sol#L780); the no-lose floor actually reverts an unprofitable trade: [`:840`](test/CompleteSetInternalizationHook.t.sol#L840) |
| Resolution → redemption lifecycle | [`freezeForResolution` / `redeemAfterResolution`, `src/CompleteSetInternalizationHook.sol:346` / `:357`](src/CompleteSetInternalizationHook.sol#L346) | [`:544`](test/CompleteSetInternalizationHook.t.sol#L544) |
| Ported CTF ID math (the highest-risk piece — must match the real contract bit-for-bit) | [`getConditionId`/`getPositionId`/`getCollectionId`, `src/libraries/CompleteSetLib.sol:63`](src/libraries/CompleteSetLib.sol#L63) onward (the alt_bn128 modular-sqrt routine runs from [`:456`](src/libraries/CompleteSetLib.sol#L456) to end of file) | Sanity-checked against itself in [`test/CompleteSetLib.t.sol`](test/CompleteSetLib.t.sol) — and verified against the **real deployed contract**, next row |
| **Proof this works against the real Gnosis contracts, not just mocks** | [`test/fork/CompleteSetInternalizationHookFork.t.sol`](test/fork/CompleteSetInternalizationHookFork.t.sol) | Forks Gnosis Chain live and runs split/merge/redeem against CTF `0xCeAfDD6b...`, plus a wrap/unwrap round trip against the legacy Wrapped1155Factory `0xEC9Cc784...`. All 4 tests pass against real bytecode |
| A runnable, working demo — not just tests | [`script/00_DeployCompleteSetInternalizationHook.s.sol`](script/00_DeployCompleteSetInternalizationHook.s.sol) | Deploys the hook, prepares a CTF condition, registers a market, and seeds hook reserve plus core AMM liquidity — see [Deploying](#deploying) |
| Full test suite | Hook (25 tests incl. 7 fuzz), library (5), quoter (4), v4 utility (6), and real-contract fork tests (4) | **44/44 passing** — run `forge test` |

## The idea

A pool trading a prediction market's YES token against its NO token has no inherent reason
to stay near 1:1 parity — nothing but the AMM curve's own liquidity resists one side being
bid up arbitrarily. This hook fixes that structurally: whenever a swap's price is already at,
past, or projected to cross 1:1 parity, the hook fills the trade itself via a fresh CTF
split — funded from its own collateral reserve — at exactly 1:1, instead of letting the AMM
curve execute at a worse price. It returns a pure `BeforeSwapDelta` NoOp, so the
`PoolManager`'s own curve is untouched for that trade.

This structurally bounds price impact the same way a $1 collateral redemption right always
does for a single outcome token, and because every collateral unit spent on a split is
recovered by the matching merge, the mechanism is capital-neutral to the hook by
construction — it protects traders without costing LPs anything on its own.

On top of that defensive backstop, the hook also opportunistically harvests real surplus for
LPs: whenever the hook's own YES/NO inventory becomes imbalanced (asymmetric trade flow),
it can sell the idle, unmatched excess directly against the pool's own AMM curve for the
deficient leg and merge the result — with a hard, contract-enforced floor that the trade can
never come back worse than what was sold, so this can never reduce LP capital.

## Architecture

```
src/
  CompleteSetInternalizationHook.sol   the hook: BaseHook + beforeSwap routing + LP reserve
  interfaces/
    ICompleteSetInternalizationHook.sol  external API, events, errors, Market struct
    IConditionalTokens.sol               minimal 0.8.x-compatible CTF interface
    IWrapped1155Factory.sol              minimal 0.8.x-compatible Wrapped1155Factory interface
  libraries/
    CompleteSetLib.sol                   CTF ID math (ported from CTHelpers.sol) + fill/sweep/
                                          harvest helpers shared by the hook
test/
  CompleteSetInternalizationHook.t.sol   end-to-end hook tests
  CompleteSetLib.t.sol                   pure-math sanity tests
  mocks/                                 0.8.26-native re-implementations of CTF/Wrapped1155Factory
```

The real `ConditionalTokens` (`lib/conditional-tokens-contracts`, pragma `^0.5.1`) and legacy
`Wrapped1155Factory` can't be imported directly into this
`^0.8.26` project, so the hook talks to them through minimal ABI-compatible interfaces, and
the test suite exercises those interfaces against 0.8.26-native mocks that reproduce the real
contracts' split/merge/redeem/wrap economics (see each mock's NatSpec for exactly what is and
isn't verified this way).

### Mechanism, in one pass through `_beforeSwap`

1. Reject if the market isn't registered or is frozen for resolution.
2. Compute the swap amount (works for both exact-input and exact-output).
3. Check whether the pool's current price is already at/past 1:1 parity in the trade's
   direction, **or** whether this trade's own size — projected against the pool's active-tick
   liquidity — would walk it there. If neither, let the AMM curve handle it.
4. If the hook's collateral reserve can't cover the fill, fall back to the AMM curve.
5. Otherwise: split the reserve into a fresh complete set, hand the trader their leg, hold the
   other, and return a `BeforeSwapDelta` that fully absorbs the swap — a pure NoOp for the
   `PoolManager`'s own curve.

### Key invariants (see `CLAUDE.md` for the full list)

1. `yesInventory + noInventory` (in complete sets) can always be merged 1:1 back to collateral.
2. When the CTF path is taken, the `PoolManager`'s own delta for that swap is exactly zero.
3. No user or LP funds can be stuck or silently lost.
4. Surplus only ever comes from a real `mergePositions` call whose proceeds exceed the
   tracked acquisition cost of what was merged — never credited out of thin air.

## Current scope

**Implemented**
- Buy-path MVP: market registration, LP collateral reserve with share-based NAV
- CTF-backstop fill for both exact-input and exact-output swaps
- Trade-impact-aware parity check (projects the trade's own price impact, not just spot price)
- Claim sweeping and automatic complete-set merging
- Opportunistic surplus harvesting against the pool's own AMM curve, with a hard no-lose floor
- Freeze-for-resolution and post-resolution redemption

**Out of scope for this MVP** (see `CLAUDE.md`): full sell-path optimization beyond what's
covered above, multi-outcome markets, advanced post-resolution auctions, intent-based/
cross-chain routing, complex fee tiers or dynamic fees.

**Known gaps / next steps**
- The Gnosis Chain factory predates per-position token metadata, so its wrappers use the generic
  `Wrapped ERC-1155` / `WMT` name and symbol. The hook now uses that deployment's two-argument ABI
  and explicit recipient payload, verified by the live fork wrap/unwrap test.

## Live deployment — Unichain Sepolia

The complete demo is deployed on Unichain Sepolia (chain ID `1301`) against the canonical Uniswap v4
PoolManager. The deployment includes the hook, quoter, demo CTF/factory/collateral, a registered
YES/NO pool, 1,000 dUSD of hook reserve, and seeded core AMM liquidity.

| Contract | Address |
|---|---|
| CompleteSetInternalizationHook | [`0xc88B...0088`](https://sepolia.uniscan.xyz/address/0xc88B0aC546a99B586199dDBeE30D801Ee1d80088) |
| CompleteSetQuoter | [`0xd4B7...eE1B`](https://sepolia.uniscan.xyz/address/0xd4B7fCecE89ABE7cAEd26aB34b548465ae05eE1B) |
| Demo collateral (dUSD) | [`0x0115...Fa31`](https://sepolia.uniscan.xyz/address/0x0115CA8539906db2d9a4beE36C64eA94a0d7Fa31) |
| YES wrapper | [`0xfF66...F339`](https://sepolia.uniscan.xyz/address/0xfF6687aB57eF24a4150f0A17755Ca24436B1F339) |
| NO wrapper | [`0x7544...21f5`](https://sepolia.uniscan.xyz/address/0x75445557CF3498CE5062F2A7BDE70161cDBE21f5) |
| Canonical v4 PoolManager | [`0x00B0...62AC`](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |

Pool ID: `0x8b82518d80bc964538ec4866ef5d91ca13e2df7d2a9885d8adf32ac715650218`.

Hook deployment transaction:
[`0x1a905214...71130623`](https://sepolia.uniscan.xyz/tx/0x1a9052149599281a934f1df96205a5d3ed9eb10aec14b2a135a83d5b71130623).

## Development

```bash
forge install
forge build
forge test
```

Note: `foundry.toml` sets `via_ir = true`. The hook and `CompleteSetLib` sit close enough to the
EIP-170 24KB deployed-code limit (`forge build --sizes` shows the current margin) that this isn't
optional — building with the legacy pipeline both fails to compile (stack-too-deep in several
functions) and produces oversized bytecode that would revert on deployment to a real network.

Run just this hook's tests:

```bash
forge test --match-contract "CompleteSet"
```

### Fork test against the real Gnosis Chain CTF

`test/fork/CompleteSetInternalizationHookFork.t.sol` runs `CompleteSetLib`'s ported CTF ID math
and the full split → merge → redeem lifecycle against the *real*, live `ConditionalTokens`
deployment on Gnosis Chain (not the mocks the rest of the suite uses) — the same contract Omen's
prediction markets run on production TVL. It requires network access and is included in a plain
`forge test` run; exclude it from an offline run with:

```bash
forge test --no-match-path "test/fork/**"
```

or run it on its own:

```bash
forge test --match-contract "CompleteSetInternalizationHookForkTest"
```

### Deploying

`script/00_DeployCompleteSetInternalizationHook.s.sol` mines a CREATE2 salt for the hook's
permission flags, deploys it, deploys a demo binary market (backed by the same mock CTF /
Wrapped1155Factory the test suite uses), registers it against a new pool, and seeds both its LP
reserve and core AMM liquidity. It supports local Anvil and Unichain Sepolia. On Unichain Sepolia it
uses the canonical Uniswap v4 PoolManager, PositionManager, Permit2, and Hookmate swap router.

Local (Anvil):

```bash
anvil
forge script script/00_DeployCompleteSetInternalizationHook.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

Against a live network, use a keystore account rather than a raw private key:

```bash
cast wallet import <KEY_NAME> --interactive

forge script script/00_DeployCompleteSetInternalizationHook.s.sol \
    --rpc-url unichain_sepolia \
    --account <KEY_NAME> \
    --sender <YOUR_WALLET_ADDRESS> \
    --broadcast
```

For Unichain Sepolia, set the RPC endpoint, obtain testnet ETH for the deployer, then deploy:

```bash
# The official public endpoint exposes flashblocks that can race Forge's fork initialization.
# PublicNode returns a fully retrievable latest block and is more reliable for deployment scripts.
export UNICHAIN_SEPOLIA_RPC_URL=https://unichain-sepolia-rpc.publicnode.com
export DEPLOYER_ADDRESS=<YOUR_WALLET_ADDRESS>

forge script script/00_DeployCompleteSetInternalizationHook.s.sol \
    --rpc-url unichain_sepolia \
    --account <KEY_NAME> \
    --sender <YOUR_WALLET_ADDRESS> \
    --broadcast \
    -vv
```

The script writes the resulting addresses to `frontend/public/deployment.json` and funds the
broadcasting wallet with demo YES/NO tokens. Build or run the frontend in testnet mode with:

```bash
cd frontend
pnpm build:unichain
# or: pnpm dev:unichain
```

The no-extension “demo trader” button is intentionally disabled on testnet because JSON-RPC account
impersonation is an Anvil-only feature; use the funded broadcasting wallet instead.

## Additional resources

- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)
- [v4-core](https://github.com/uniswap/v4-core) / [v4-periphery](https://github.com/uniswap/v4-periphery)
- [Gnosis Conditional Tokens Framework](https://github.com/gnosis/conditional-tokens-contracts)
- [Gnosis Wrapped1155Factory](https://github.com/gnosis/1155-to-20)
