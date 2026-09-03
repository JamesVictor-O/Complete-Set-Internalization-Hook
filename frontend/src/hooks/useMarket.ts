import { useReadContract } from "wagmi";
import type { Address, Hex } from "viem";
import { hookAbi, stateViewAbi } from "../config/contracts";
import type { Market } from "../config/types";
import { stateViewAddress, targetChain } from "../config/chain";

/// Reads the hook's full condition-level `Market` struct. `refetchInterval` keeps the demo's reserve /
/// inventory figures live without the user having to manually refresh after every swap or merge from
/// another tab (e.g. the deploy script's own demo trader).
export function useMarket(hookAddress: Address | undefined, marketId: Hex | undefined) {
  return useReadContract({
    address: hookAddress,
    chainId: targetChain.id,
    abi: hookAbi,
    functionName: "getMarket",
    args: marketId ? [marketId] : undefined,
    query: {
      enabled: Boolean(hookAddress && marketId),
      refetchInterval: 4000,
      // A swap/merge/sweep in one panel should be visible in every other panel's numbers without a
      // manual refresh — react-query pauses `refetchInterval` in a backgrounded tab by default, which
      // would otherwise leave a demo dashboard showing stale figures until the tab regains focus.
      refetchIntervalInBackground: true,
      select: (data) => data as unknown as Market,
    },
  });
}

export function useLpShares(hookAddress: Address | undefined, marketId: Hex | undefined, owner: Address | undefined) {
  return useReadContract({
    address: hookAddress,
    chainId: targetChain.id,
    abi: hookAbi,
    functionName: "sharesOf",
    args: marketId && owner ? [marketId, owner] : undefined,
    query: {
      enabled: Boolean(hookAddress && marketId && owner),
      refetchInterval: 4000,
      // A swap/merge/sweep in one panel should be visible in every other panel's numbers without a
      // manual refresh — react-query pauses `refetchInterval` in a backgrounded tab by default, which
      // would otherwise leave a demo dashboard showing stale figures until the tab regains focus.
      refetchIntervalInBackground: true,
    },
  });
}

/// Reads the Uniswap v4 pool liquidity that is active at the current tick. This
/// is AMM curve liquidity, not the hook's separate dUSD backstop reserve.
export function useAmmLiquidity(poolId: Hex | undefined) {
  return useReadContract({
    address: stateViewAddress,
    chainId: targetChain.id,
    abi: stateViewAbi,
    functionName: "getLiquidity",
    args: poolId ? [poolId] : undefined,
    query: {
      enabled: Boolean(stateViewAddress && poolId),
      refetchInterval: 4000,
      refetchIntervalInBackground: true,
    },
  });
}
