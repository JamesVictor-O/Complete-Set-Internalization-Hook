import { defineChain } from "viem";

/// The only chain this demo targets: a local Anvil node running the deploy script's output.
/// `script/00_DeployCompleteSetInternalizationHookScript.s.sol` only writes real, dereferenceable
/// addresses for chainId 31337 — pointing this at anything else would just be wrong data.
export const anvilLocal = defineChain({
  id: 31337,
  name: "Anvil Local",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
});
