import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { erc20Abi } from "../abi/erc20";
import { targetChain } from "../config/chain";

export function useTokenBalance(token: Address | undefined, owner: Address | undefined) {
  return useReadContract({
    address: token,
    chainId: targetChain.id,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: owner ? [owner] : undefined,
    query: {
      enabled: Boolean(token && owner),
      refetchInterval: 4000,
      refetchIntervalInBackground: true,
    },
  });
}

export function useTokenAllowance(
  token: Address | undefined,
  owner: Address | undefined,
  spender: Address | undefined,
) {
  return useReadContract({
    address: token,
    chainId: targetChain.id,
    abi: erc20Abi,
    functionName: "allowance",
    args: owner && spender ? [owner, spender] : undefined,
    query: {
      enabled: Boolean(token && owner && spender),
    },
  });
}
