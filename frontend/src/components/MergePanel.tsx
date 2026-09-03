import type { Deployment } from "../config/deployment";
import { useAppWallet } from "../hooks/useAppWallet";
import { usePendingTx } from "../hooks/usePendingTx";
import { hookAbi } from "../config/contracts";

/// Both actions here are permissionless — anyone can sweep pending swap-fill claims into real CTF
/// inventory, or merge overlapping YES/NO inventory back into collateral. Exposed as standalone buttons
/// so the demo can show the two-step "fill now, settle later" flow from the hook's own NatSpec explicitly
/// rather than hiding it inside an automatic background poller.
export function MergePanel({ deployment }: { deployment: Deployment }) {
  const { isConnected, writeContract, isWriting } = useAppWallet();
  const sweepTx = usePendingTx();

  async function handleSweep() {
    const hash = await writeContract({
      address: deployment.hook,
      abi: hookAbi,
      functionName: "sweepCollateralClaims",
      args: [deployment.marketId],
    });
    sweepTx.setHash(hash);
  }

  return (
    <section className="panel">
      <h2>Claim settlement</h2>
      <p className="subtle">
        A synthetic fill receives its net dUSD payment as a PoolManager claim. Sweep converts it into real collateral and
        restores the hook's working-capital reserve after the router settles.
      </p>
      <button type="button" className="btn btn-ghost" disabled={!isConnected || isWriting} onClick={handleSweep}>
        {sweepTx.isConfirming ? "Settling…" : "Settle dUSD claim"}
      </button>
    </section>
  );
}
