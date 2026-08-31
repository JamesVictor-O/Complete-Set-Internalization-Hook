import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { quoterAbi } from "../config/contracts";
import type { PoolKeyJson } from "../config/deployment";
import type { QuoteResult } from "../config/types";
import { targetChain } from "../config/chain";

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
    chainId: targetChain.id,
    abi: quoterAbi,
    functionName: "quote",
    args: poolKey && amountIn !== undefined ? [poolKey, zeroForOne, amountIn] : undefined,
    query: {
      enabled: Boolean(quoterAddress && poolKey && amountIn && amountIn > 0n),
      select: (data) => data as unknown as QuoteResult,
    },
  });
}
