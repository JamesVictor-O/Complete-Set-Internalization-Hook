import { useMemo, useState } from "react";
import { parseUnits } from "viem";
import { usePublicClient } from "wagmi";
import type { Deployment } from "../config/deployment";
import { useAppWallet } from "../hooks/useAppWallet";
import { useQuote } from "../hooks/useQuote";
import { useTokenAllowance, useTokenBalance } from "../hooks/useToken";
import { erc20Abi } from "../abi/erc20";
import { routerAbi } from "../config/contracts";
import { targetChain } from "../config/chain";
import { formatBps, formatToken, formatWadPrice } from "../lib/format";
import type { SwapQuote } from "../config/types";

const DEADLINE_SECONDS = 3600n;
const SLIPPAGE_BPS = 100n; // 1%, generous for a local demo
type SwapStage = "idle" | "approving" | "swapping" | "success";

export function SwapPanel({ deployment }: { deployment: Deployment }) {
  const { address, isConnected, writeContract, isWriting } = useAppWallet();
  const publicClient = usePublicClient({ chainId: targetChain.id });
  const [payYes, setPayYes] = useState(true);
  const [amountText, setAmountText] = useState("10");
  const [stage, setStage] = useState<SwapStage>("idle");
  const [flowError, setFlowError] = useState<string>();
  const [flowNeedsApproval, setFlowNeedsApproval] = useState(false);

  const payToken = payYes ? deployment.yesToken : deployment.noToken;
  const receiveToken = payYes ? deployment.noToken : deployment.yesToken;
  const zeroForOne = payToken.toLowerCase() === deployment.poolKey.currency0.toLowerCase();

  const amountIn = useMemo(() => {
    try {
      return amountText.trim() === "" ? undefined : parseUnits(amountText, 18);
    } catch {
      return undefined;
    }
  }, [amountText]);

  const { data: quoteResult } = useQuote(deployment.quoter, deployment.poolKey, zeroForOne, amountIn);
  const { data: payBalance, refetch: refetchBalance } = useTokenBalance(payToken, address);
  const { data: receiveBalance, refetch: refetchReceiveBalance } = useTokenBalance(receiveToken, address);
  const { data: allowance, refetch: refetchAllowance } = useTokenAllowance(payToken, address, deployment.swapRouter);

  const needsApproval = amountIn !== undefined && (allowance === undefined || allowance < amountIn);
  const isBusy = stage === "approving" || stage === "swapping";

  async function handleSwap() {
    if (!address || amountIn === undefined || !publicClient) return;
    setFlowError(undefined);
    setStage("idle");
    setFlowNeedsApproval(needsApproval);

    const expectedOut = quoteResult?.recommendCtf
      ? quoteResult.ctfQuote.outAmount
      : (quoteResult?.ammQuote.outAmount ?? 0n);
    const amountOutMin = expectedOut > 0n ? (expectedOut * (10_000n - SLIPPAGE_BPS)) / 10_000n : 0n;
    const deadline = BigInt(Math.floor(Date.now() / 1000)) + DEADLINE_SECONDS;

    try {
      if (needsApproval) {
        setStage("approving");
        const approvalHash = await writeContract({
          address: payToken,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.swapRouter, amountIn],
        });
        const approvalReceipt = await publicClient.waitForTransactionReceipt({ hash: approvalHash });
        if (approvalReceipt.status !== "success") throw new Error("Token approval failed on-chain.");
        await refetchAllowance();
      }

      // The second wallet request opens automatically as soon as approval confirms.
      setStage("swapping");
      const swapHash = await writeContract({
        address: deployment.swapRouter,
        abi: routerAbi,
        functionName: "swapExactTokensForTokens",
        args: [amountIn, amountOutMin, zeroForOne, deployment.poolKey, "0x", address, deadline],
      });
      const swapReceipt = await publicClient.waitForTransactionReceipt({ hash: swapHash });
      if (swapReceipt.status !== "success") throw new Error("Swap failed on-chain.");

      await Promise.all([refetchBalance(), refetchReceiveBalance(), refetchAllowance()]);
      setStage("success");
    } catch (error) {
      setStage("idle");
      setFlowError(readableTransactionError(error));
    }
  }

  return (
    <section className="panel">
      <h2>Swap</h2>
      <div className="field-row">
        <label htmlFor="pay-token">Pay</label>
        <select
          id="pay-token"
          value={payYes ? "yes" : "no"}
          disabled={isBusy}
          onChange={(e) => {
            setPayYes(e.target.value === "yes");
            setStage("idle");
            setFlowError(undefined);
            setFlowNeedsApproval(false);
          }}
        >
          <option value="yes">YES</option>
          <option value="no">NO</option>
        </select>
        <input
          type="number"
          min="0"
          step="any"
          value={amountText}
          disabled={isBusy}
          onChange={(e) => {
            setAmountText(e.target.value);
            setStage("idle");
            setFlowError(undefined);
            setFlowNeedsApproval(false);
          }}
        />
      </div>
      <p className="subtle">
        Balance: {formatToken(payBalance as bigint | undefined)} {payYes ? "YES" : "NO"} · receiving{" "}
        {payYes ? "NO" : "YES"} (balance {formatToken(receiveBalance as bigint | undefined)})
      </p>

      {quoteResult && (
        <div className="quote-box">
          <QuoteRow label="AMM curve" quote={quoteResult.ammQuote} />
          <QuoteRow label="CTF backstop" quote={quoteResult.ctfQuote} />
          <p className="recommend">
            Hook will route via: <strong>{quoteResult.recommendCtf ? "CTF backstop (1:1)" : "AMM curve"}</strong>
          </p>
        </div>
      )}

      {stage === "approving" && (
        <p className="subtle" role="status" aria-live="polite">
          Step 1 of 2 · Confirm {payYes ? "YES" : "NO"} access in your wallet. The swap confirmation will
          open automatically after approval confirms.
        </p>
      )}
      {stage === "swapping" && (
        <p className="subtle" role="status" aria-live="polite">
          {flowNeedsApproval ? "Step 2 of 2" : "Final step"} · Confirm the swap in your wallet.
        </p>
      )}
      {stage === "success" && (
        <p className="recommend" role="status" aria-live="polite">
          Swap confirmed. Your balances are up to date.
        </p>
      )}
      {flowError && (
        <p className="warn" role="alert">
          {flowError} Your tokens have not been swapped. Try again when ready.
        </p>
      )}

      {!isConnected ? (
        <p className="subtle">Connect a wallet to swap.</p>
      ) : (
        <button
          type="button"
          className="btn btn-primary"
          disabled={isWriting || isBusy || !amountIn || amountIn === 0n}
          aria-busy={isBusy}
          onClick={handleSwap}
        >
          {stage === "approving" ? "Approving…" : stage === "swapping" ? "Swapping…" : "Swap"}
        </button>
      )}
    </section>
  );
}

function readableTransactionError(error: unknown): string {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  if (message.includes("user rejected") || message.includes("user denied")) {
    return "The wallet request was cancelled.";
  }
  if (message.includes("revert")) return "The transaction reverted on-chain.";
  if (message.includes("insufficient funds")) return "The wallet does not have enough test ETH for gas.";
  return "The wallet could not complete the transaction.";
}

function QuoteRow({ label, quote }: { label: string; quote: SwapQuote }) {
  return (
    <div className="quote-row">
      <span>{label}</span>
      {quote.available ? (
        <span>
          {formatToken(quote.outAmount)} out · {formatWadPrice(quote.effectivePriceWad)} ·{" "}
          {formatBps(quote.priceImpactBps)} impact
        </span>
      ) : (
        <span className="subtle">unavailable</span>
      )}
    </div>
  );
}
