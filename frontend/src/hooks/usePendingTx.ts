import { useState } from "react";
import { useWaitForTransactionReceipt } from "wagmi";
import type { Hash } from "viem";

/// Tracks one in-flight transaction's confirmation status. Every action panel (swap, deposit/withdraw,
/// merge) owns one of these — callers `setHash` right after submitting and watch `isConfirmed` to know
/// when to refetch the reads that action affects.
export function usePendingTx() {
  const [hash, setHash] = useState<Hash | undefined>();
  const { isLoading: isConfirming, isSuccess: isConfirmed, isError } = useWaitForTransactionReceipt({ hash });
  return { hash, setHash, isConfirming, isConfirmed, isError };
}
