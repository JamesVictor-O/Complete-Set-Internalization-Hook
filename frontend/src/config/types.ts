/// Hand-written mirrors of on-chain struct shapes. The generated ABI JSON is imported as a loosely
/// typed `Abi` (see `contracts.ts`), so `useReadContract` can't infer these automatically — these types
/// keep the component code honest about what each read actually returns.

export interface SwapQuote {
  outAmount: bigint;
  effectivePriceWad: bigint;
  priceImpactBps: bigint;
  available: boolean;
}

export interface QuoteResult {
  ammQuote: SwapQuote;
  ctfQuote: SwapQuote;
  recommendCtf: boolean;
}

export interface Market {
  registered: boolean;
  frozen: boolean;
  collateralToken: string;
  conditionId: `0x${string}`;
  yesCurrency: string;
  noCurrency: string;
  yesPositionId: bigint;
  noPositionId: bigint;
  yesWrapData: `0x${string}`;
  noWrapData: `0x${string}`;
  collateralReserve: bigint;
  outstandingSplitCost: bigint;
  yesInventory: bigint;
  noInventory: bigint;
  yesClaimBalance: bigint;
  noClaimBalance: bigint;
  totalShares: bigint;
  lifetimeSurplus: bigint;
}
