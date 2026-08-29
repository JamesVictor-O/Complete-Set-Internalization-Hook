import { useEffect, useMemo, useState } from "react";
import { parseUnits, type Hex } from "viem";
import type { Deployment } from "../config/deployment";
import { useAppWallet } from "../hooks/useAppWallet";
import { useLpShares } from "../hooks/useMarket";
import { useTokenAllowance, useTokenBalance } from "../hooks/useToken";
import { usePendingTx } from "../hooks/usePendingTx";
import { erc20Abi } from "../abi/erc20";
import { hookAbi } from "../config/contracts";
import { formatToken } from "../lib/format";

export function LiquidityPanel({ deployment, poolId }: { deployment: Deployment; poolId: Hex }) {
  const { address, isConnected, writeContract, isWriting } = useAppWallet();
  const [depositText, setDepositText] = useState("100");
  const [withdrawText, setWithdrawText] = useState("0");

  const depositAmount = useMemo(() => safeParse(depositText), [depositText]);
  const withdrawShares = useMemo(() => safeParse(withdrawText), [withdrawText]);

  const { data: collateralBalance, refetch: refetchCollateral } = useTokenBalance(
    deployment.collateralToken,
    address,
  );
  const { data: allowance, refetch: refetchAllowance } = useTokenAllowance(
    deployment.collateralToken,
    address,
    deployment.hook,
  );
  const { data: myShares, refetch: refetchShares } = useLpShares(deployment.hook, poolId, address);

  const depositTx = usePendingTx();
  const withdrawTx = usePendingTx();
  const approveTx = usePendingTx();

  const needsApproval = depositAmount !== undefined && (allowance === undefined || allowance < depositAmount);

  useEffect(() => {
    if (!depositTx.isConfirmed && !withdrawTx.isConfirmed) return;
    void refetchCollateral();
    void refetchAllowance();
    void refetchShares();
  }, [depositTx.isConfirmed, withdrawTx.isConfirmed, refetchCollateral, refetchAllowance, refetchShares]);

  async function handleApprove() {
    const hash = await writeContract({
      address: deployment.collateralToken,
      abi: erc20Abi,
      functionName: "approve",
      args: [deployment.hook, depositAmount ?? 0n],
    });
    approveTx.setHash(hash);
  }

  async function handleDeposit() {
    if (depositAmount === undefined) return;
    const hash = await writeContract({
      address: deployment.hook,
      abi: hookAbi,
      functionName: "depositCollateral",
      args: [deployment.poolKey, depositAmount],
    });
    depositTx.setHash(hash);
  }

  async function handleWithdraw() {
    if (withdrawShares === undefined) return;
    const hash = await writeContract({
      address: deployment.hook,
      abi: hookAbi,
      functionName: "withdrawCollateral",
      args: [deployment.poolKey, withdrawShares],
    });
    withdrawTx.setHash(hash);
  }

  return (
    <section className="panel">
      <h2>Liquidity</h2>
      <p className="subtle">
        Your shares: {formatToken(myShares as bigint | undefined)} · Balance:{" "}
        {formatToken(collateralBalance as bigint | undefined)} dUSD
      </p>

      <div className="field-row">
        <label htmlFor="deposit-amount">Deposit dUSD</label>
        <input
          id="deposit-amount"
          type="number"
          min="0"
          step="any"
          value={depositText}
          onChange={(e) => setDepositText(e.target.value)}
        />
      </div>
      {!isConnected ? null : needsApproval ? (
        <button type="button" className="btn btn-primary" disabled={isWriting} onClick={handleApprove}>
          {approveTx.isConfirming ? "Approving…" : "Approve dUSD"}
        </button>
      ) : (
        <button type="button" className="btn btn-primary" disabled={isWriting || !depositAmount} onClick={handleDeposit}>
          {depositTx.isConfirming ? "Depositing…" : "Deposit"}
        </button>
      )}

      <div className="field-row">
        <label htmlFor="withdraw-shares">Withdraw shares</label>
        <input
          id="withdraw-shares"
          type="number"
          min="0"
          step="any"
          value={withdrawText}
          onChange={(e) => setWithdrawText(e.target.value)}
        />
      </div>
      {isConnected && (
        <button
          type="button"
          className="btn btn-ghost"
          disabled={isWriting || !withdrawShares}
          onClick={handleWithdraw}
        >
          {withdrawTx.isConfirming ? "Withdrawing…" : "Withdraw"}
        </button>
      )}
    </section>
  );
}

function safeParse(text: string): bigint | undefined {
  try {
    return text.trim() === "" ? undefined : parseUnits(text, 18);
  } catch {
    return undefined;
  }
}
