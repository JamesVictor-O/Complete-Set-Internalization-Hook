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
  const mergeTx = usePendingTx();

  async function handleSweep() {
    const hash = await writeContract({
      address: deployment.hook,
      abi: hookAbi,
      functionName: "sweepClaims",
      args: [deployment.poolKey],
    });
    sweepTx.setHash(hash);
  }

  async function handleMerge() {
    const hash = await writeContract({
      address: deployment.hook,
      abi: hookAbi,
      functionName: "mergeIfPossible",
      args: [deployment.poolKey],
    });
    mergeTx.setHash(hash);
  }

  return (
    <section className="panel">
      <h2>Settlement</h2>
      <p className="subtle">
        A CTF-filled swap only mints the hook an ERC-6909 claim mid-swap — sweep converts that into real
        inventory once the router has settled. Merge recombines overlapping YES/NO inventory back into
        collateral for LPs.
      </p>
      <div className="button-row">
        <button type="button" className="btn btn-ghost" disabled={!isConnected || isWriting} onClick={handleSweep}>
          {sweepTx.isConfirming ? "Sweeping…" : "Sweep claims"}
        </button>
        <button type="button" className="btn btn-ghost" disabled={!isConnected || isWriting} onClick={handleMerge}>
          {mergeTx.isConfirming ? "Merging…" : "Merge inventory"}
        </button>
      </div>
    </section>
  );
}
