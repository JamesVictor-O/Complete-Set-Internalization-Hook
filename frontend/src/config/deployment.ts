import type { Address } from "viem";

export interface PoolKeyJson {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

export interface Deployment {
  chainId: number;
  hook: Address;
  quoter: Address;
  poolManager: Address;
  swapRouter: Address;
  permit2: Address;
  collateralToken: Address;
  yesToken: Address;
  noToken: Address;
  demoTrader: Address;
  marketQuestion: string;
  marketId: `0x${string}`;
  yesPoolKey: PoolKeyJson;
  noPoolKey: PoolKeyJson;
}

/// Fetches `/deployment.json`, written by `script/00_DeployCompleteSetInternalizationHook.s.sol`.
/// There is deliberately no build-time import of this file — it doesn't exist until a deploy has run,
/// and its addresses change on every fresh local deploy.
export async function fetchDeployment(): Promise<Deployment> {
  const res = await fetch("/deployment.json");
  if (!res.ok) {
    throw new Error(`Failed to load /deployment.json (${res.status}) — run the deploy script first`);
  }
  const deployment = (await res.json()) as Deployment;
  if (!deployment.yesPoolKey || !deployment.noPoolKey) {
    throw new Error("deployment.json is from the superseded YES/NO design; deploy the corrected outcome/dUSD pools");
  }
  return deployment;
}
