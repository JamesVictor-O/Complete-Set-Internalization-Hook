import { useEffect, useMemo, useState } from "react";
import { parseUnits } from "viem";
import type { Deployment } from "../config/deployment";
import { useAppWallet } from "../hooks/useAppWallet";
import { useQuote } from "../hooks/useQuote";
import { useTokenAllowance, useTokenBalance } from "../hooks/useToken";
import { usePendingTx } from "../hooks/usePendingTx";
import { erc20Abi } from "../abi/erc20";
import { routerAbi } from "../config/contracts";
import { formatBps, formatToken, formatWadPrice } from "../lib/format";
import type { SwapQuote } from "../config/types";

const DEADLINE_SECONDS = 3600n;
const SLIPPAGE_BPS = 100n; // 1%, generous for a local demo

export function SwapPanel({ deployment }: { deployment: Deployment }) {
  const { address, isConnected, writeContract, isWriting } = useAppWallet();
  const [payYes, setPayYes] = useState(true);
  const [amountText, setAmountText] = useState("10");

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

  const approveTx = usePendingTx();
  const swapTx = usePendingTx();

  const needsApproval = amountIn !== undefined && (allowance === undefined || allowance < amountIn);

  async function handleApprove() {
    const hash = await writeContract({
      address: payToken,
      abi: erc20Abi,
      functionName: "approve",
      args: [deployment.swapRouter, amountIn ?? 0n],
    });
    approveTx.setHash(hash);
  }

  async function handleSwap() {
    if (!address || amountIn === undefined) return;
    const expectedOut = quoteResult?.recommendCtf
      ? quoteResult.ctfQuote.outAmount
      : (quoteResult?.ammQuote.outAmount ?? 0n);
    const amountOutMin = expectedOut > 0n ? (expectedOut * (10_000n - SLIPPAGE_BPS)) / 10_000n : 0n;
    const deadline = BigInt(Math.floor(Date.now() / 1000)) + DEADLINE_SECONDS;

    const hash = await writeContract({
      address: deployment.swapRouter,
      abi: routerAbi,
      functionName: "swapExactTokensForTokens",
      args: [amountIn, amountOutMin, zeroForOne, deployment.poolKey, "0x", address, deadline],
    });
    swapTx.setHash(hash);
  }

  useEffect(() => {
    if (!swapTx.isConfirmed) return;
    void refetchBalance();
    void refetchReceiveBalance();
    void refetchAllowance();
  }, [swapTx.isConfirmed, refetchBalance, refetchReceiveBalance, refetchAllowance]);

  return (
    <section className="panel">
      <h2>Swap</h2>
      <div className="field-row">
        <label htmlFor="pay-token">Pay</label>
        <select id="pay-token" value={payYes ? "yes" : "no"} onChange={(e) => setPayYes(e.target.value === "yes")}>
          <option value="yes">YES</option>
          <option value="no">NO</option>
        </select>
        <input
          type="number"
          min="0"
          step="any"
          value={amountText}
          onChange={(e) => setAmountText(e.target.value)}
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

      {!isConnected ? (
        <p className="subtle">Connect a wallet to swap.</p>
      ) : needsApproval ? (
        <button type="button" className="btn btn-primary" disabled={isWriting || !amountIn} onClick={handleApprove}>
          {approveTx.isConfirming ? "Approving…" : `Approve ${payYes ? "YES" : "NO"}`}
        </button>
      ) : (
        <button
          type="button"
          className="btn btn-primary"
          disabled={isWriting || !amountIn || amountIn === 0n}
          onClick={handleSwap}
        >
          {swapTx.isConfirming ? "Swapping…" : "Swap"}
        </button>
      )}
    </section>
  );
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
