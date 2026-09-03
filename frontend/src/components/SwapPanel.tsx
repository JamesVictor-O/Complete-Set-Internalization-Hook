import { useMemo, useState } from "react";
import { parseUnits } from "viem";
import { usePublicClient } from "wagmi";
import type { Deployment, PoolKeyJson } from "../config/deployment";
import { useAppWallet } from "../hooks/useAppWallet";
import { useQuote } from "../hooks/useQuote";
import { useTokenAllowance, useTokenBalance } from "../hooks/useToken";
import { erc20Abi } from "../abi/erc20";
import { routerAbi } from "../config/contracts";
import { targetChain } from "../config/chain";
import { formatToken } from "../lib/format";
import type { ExecutionQuote } from "../config/types";

const DEADLINE_SECONDS = 3600n;
const SLIPPAGE_BPS = 100n; // 1%, generous for a local demo
type SwapStage = "idle" | "approving" | "swapping" | "success";

export function SwapPanel({ deployment, poolKey, outcome }: { deployment: Deployment; poolKey: PoolKeyJson; outcome: "YES" | "NO" }) {
  const { address, isConnected, writeContract, isWriting } = useAppWallet();
  const publicClient = usePublicClient({ chainId: targetChain.id });
  const [buyOutcome, setBuyOutcome] = useState(true);
  const [amountText, setAmountText] = useState("10");
  const [stage, setStage] = useState<SwapStage>("idle");
  const [flowError, setFlowError] = useState<string>();
  const [flowNeedsApproval, setFlowNeedsApproval] = useState(false);

  const outcomeToken = outcome === "YES" ? deployment.yesToken : deployment.noToken;
  const payToken = buyOutcome ? deployment.collateralToken : outcomeToken;
  const receiveToken = buyOutcome ? outcomeToken : deployment.collateralToken;
  const zeroForOne = payToken.toLowerCase() === poolKey.currency0.toLowerCase();

  const amountIn = useMemo(() => {
    try {
      return amountText.trim() === "" ? undefined : parseUnits(amountText, 18);
    } catch {
      return undefined;
    }
  }, [amountText]);

  const { data: quoteResult } = useQuote(deployment.quoter, poolKey, zeroForOne, amountIn);
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

    const expectedOut = quoteResult?.recommendSynthetic
      ? quoteResult.syntheticQuote.amount
      : (quoteResult?.ammQuote.amount ?? 0n);
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
        args: [amountIn, amountOutMin, zeroForOne, poolKey, "0x", address, deadline],
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
          value={buyOutcome ? "buy" : "sell"}
          disabled={isBusy}
          onChange={(e) => {
            setBuyOutcome(e.target.value === "buy");
            setStage("idle");
            setFlowError(undefined);
            setFlowNeedsApproval(false);
          }}
        >
          <option value="buy">dUSD (buy {outcome})</option>
          <option value="sell">{outcome} (sell for dUSD)</option>
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
        Balance: {formatToken(payBalance as bigint | undefined)} {buyOutcome ? "dUSD" : outcome} · receiving{" "}
        {buyOutcome ? outcome : "dUSD"} (balance {formatToken(receiveBalance as bigint | undefined)})
      </p>

      {quoteResult && (
        <div className="quote-box">
          <QuoteRow label={`${outcome}/dUSD AMM`} quote={quoteResult.ammQuote} />
          <QuoteRow label="Executable complete-set route" quote={quoteResult.syntheticQuote} />
          <p className="recommend">
            Best execution: <strong>{quoteResult.recommendSynthetic ? "CTF + complementary pool" : `${outcome}/dUSD AMM`}</strong>
          </p>
          {buyOutcome && !quoteResult.syntheticQuote.available && (
            <p className="subtle">The synthetic route is unavailable at this size. The complementary pool may be too thin, or reserve collateral may be insufficient.</p>
          )}
        </div>
      )}

      {stage === "approving" && (
        <p className="subtle" role="status" aria-live="polite">
          Step 1 of 2 · Confirm {buyOutcome ? "dUSD" : outcome} access in your wallet. The swap confirmation will
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

function QuoteRow({ label, quote }: { label: string; quote: ExecutionQuote }) {
  return (
    <div className="quote-row">
      <span>{label}</span>
      {quote.available ? (
        <span>
          {formatToken(quote.amount)} out
          {quote.complementProceeds > 0n ? ` · complement sale ${formatToken(quote.complementProceeds)} dUSD` : ""}
        </span>
      ) : (
        <span className="subtle">unavailable</span>
      )}
    </div>
  );
}
