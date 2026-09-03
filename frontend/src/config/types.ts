import type { PoolKeyJson } from "./deployment";

export interface ExecutionQuote {
  amount: bigint;
  complementProceeds: bigint;
  reserveRequired: bigint;
  available: boolean;
}

export interface QuoteResult {
  ammQuote: ExecutionQuote;
  syntheticQuote: ExecutionQuote;
  recommendSynthetic: boolean;
}

export interface Market {
  registered: boolean;
  frozen: boolean;
  collateralToken: string;
  collateralCurrency: string;
  conditionId: `0x${string}`;
  yesCurrency: string;
  noCurrency: string;
  yesPoolKey: PoolKeyJson;
  noPoolKey: PoolKeyJson;
  yesPoolId: `0x${string}`;
  noPoolId: `0x${string}`;
  yesPositionId: bigint;
  noPositionId: bigint;
  yesWrapData: `0x${string}`;
  noWrapData: `0x${string}`;
  freeCollateral: bigint;
  pendingCollateralClaims: bigint;
  yesInventory: bigint;
  noInventory: bigint;
  totalShares: bigint;
  lifetimeSurplus: bigint;
}
