import { useReadContract } from "wagmi";
import type { Address, Hex } from "viem";
import { hookAbi } from "../config/contracts";
import type { Market } from "../config/types";
import { targetChain } from "../config/chain";

/// Reads the hook's full `Market` struct for `poolId`. `refetchInterval` keeps the demo's reserve /
/// inventory figures live without the user having to manually refresh after every swap or merge from
/// another tab (e.g. the deploy script's own demo trader).
export function useMarket(hookAddress: Address | undefined, poolId: Hex | undefined) {
  return useReadContract({
    address: hookAddress,
    chainId: targetChain.id,
    abi: hookAbi,
    functionName: "getMarket",
    args: poolId ? [poolId] : undefined,
    query: {
      enabled: Boolean(hookAddress && poolId),
      refetchInterval: 4000,
      // A swap/merge/sweep in one panel should be visible in every other panel's numbers without a
      // manual refresh — react-query pauses `refetchInterval` in a backgrounded tab by default, which
      // would otherwise leave a demo dashboard showing stale figures until the tab regains focus.
      refetchIntervalInBackground: true,
      select: (data) => data as unknown as Market,
    },
  });
}

export function useLpShares(hookAddress: Address | undefined, poolId: Hex | undefined, owner: Address | undefined) {
  return useReadContract({
    address: hookAddress,
    chainId: targetChain.id,
    abi: hookAbi,
    functionName: "sharesOf",
    args: poolId && owner ? [poolId, owner] : undefined,
    query: {
      enabled: Boolean(hookAddress && poolId && owner),
      refetchInterval: 4000,
      // A swap/merge/sweep in one panel should be visible in every other panel's numbers without a
      // manual refresh — react-query pauses `refetchInterval` in a backgrounded tab by default, which
      // would otherwise leave a demo dashboard showing stale figures until the tab regains focus.
      refetchIntervalInBackground: true,
    },
  });
}
