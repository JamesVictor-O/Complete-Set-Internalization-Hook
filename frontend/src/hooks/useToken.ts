import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { erc20Abi } from "../abi/erc20";

export function useTokenBalance(token: Address | undefined, owner: Address | undefined) {
  return useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: owner ? [owner] : undefined,
    query: {
      enabled: Boolean(token && owner),
      refetchInterval: 4000,
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
    abi: erc20Abi,
    functionName: "allowance",
    args: owner && spender ? [owner, spender] : undefined,
    query: {
      enabled: Boolean(token && owner && spender),
    },
  });
}
