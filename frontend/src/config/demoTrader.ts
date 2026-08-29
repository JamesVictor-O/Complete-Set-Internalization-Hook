import { createWalletClient, http, type Address } from "viem";
import { anvilLocal } from "./chain";

/// "Connect as demo trader" needs no wallet extension and no embedded private key: Anvil's default
/// accounts (funded by `script/00_DeployCompleteSetInternalizationHookScript.s.sol`) are accounts Anvil
/// itself holds the keys for, so it signs any `eth_sendTransaction` sent with `from` set to one of them.
/// Passing a bare address (not a `privateKeyToAccount` object) makes viem's wallet client use exactly
/// that JSON-RPC signing path — this only ever works against a local Anvil node, never a real chain.
export function createDemoTraderClient(address: Address) {
  return createWalletClient({
    account: address,
    chain: anvilLocal,
    transport: http(),
  });
}

export type DemoTraderClient = ReturnType<typeof createDemoTraderClient>;
