import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { quoterAbi } from "../config/contracts";
import type { PoolKeyJson } from "../config/deployment";
import type { QuoteResult } from "../config/types";

/// Live AMM-vs-CTF comparison from {CompleteSetQuoter}, mirroring exactly what
/// `CompleteSetInternalizationHook._beforeSwap` would decide for the same trade.
export function useQuote(
  quoterAddress: Address | undefined,
  poolKey: PoolKeyJson | undefined,
  zeroForOne: boolean,
  amountIn: bigint | undefined,
) {
  return useReadContract({
    address: quoterAddress,
    abi: quoterAbi,
    functionName: "quote",
    args: poolKey && amountIn !== undefined ? [poolKey, zeroForOne, amountIn] : undefined,
    query: {
      enabled: Boolean(quoterAddress && poolKey && amountIn && amountIn > 0n),
      select: (data) => data as unknown as QuoteResult,
    },
  });
}
