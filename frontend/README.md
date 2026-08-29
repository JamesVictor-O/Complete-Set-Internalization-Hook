# Complete-Set Internalization Hook — demo frontend

A minimal React + wagmi/viem dashboard for the hook: shows live market state (LP reserve, YES/NO
inventory, pending claims), lets you swap YES↔NO and see the AMM-vs-CTF quote comparison the hook itself
uses to route the trade, manage LP collateral, and trigger the permissionless claim-sweep / merge steps.

Talks only to a local Anvil node (chain id `31337`) running the project's own deploy script — there is no
support for any other network.

## Running the demo

From the repository root (`complete-set-hook/`), in three terminals:

```bash
# 1. local chain
anvil

# 2. deploy the hook + a demo market, seed LP reserve and core AMM liquidity,
#    fund a well-known local "demo trader" account, and write frontend/public/deployment.json
forge script script/00_DeployCompleteSetInternalizationHook.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --non-interactive \
  --private-key <anvil-account-0-private-key>

# 3. frontend
cd frontend
pnpm install
pnpm dev
```

Open the printed local URL. Either connect a real wallet pointed at `http://127.0.0.1:8545` (chain id
`31337`), or click **Use demo trader** — this signs as the Anvil account the deploy script pre-funded with
YES/NO tokens, with no wallet extension or private key needed client-side (Anvil signs for its own default
accounts automatically).

Re-running the deploy script produces a fresh market at new addresses; just refresh the page afterward —
`deployment.json` is read on load, not cached.
