import { useMemo } from "react";
import { useAccount } from "wagmi";
import { useDeployment } from "./hooks/useDeployment";
import { useAppWallet } from "./hooks/useAppWallet";
import { computePoolId } from "./config/poolId";
import { targetChain } from "./config/chain";
import { WalletBar } from "./components/WalletBar";
import { MarketPanel } from "./components/MarketPanel";
import { SwapPanel } from "./components/SwapPanel";
import { LiquidityPanel } from "./components/LiquidityPanel";
import { MergePanel } from "./components/MergePanel";
import "./App.css";

function App() {
  const { data: deployment, isLoading, error } = useDeployment();
  const { chainId, isConnected } = useAccount();
  const { switchNetwork, isSwitchingNetwork } = useAppWallet();
  const poolId = useMemo(() => (deployment ? computePoolId(deployment.poolKey) : undefined), [deployment]);

  return (
    <div className="app">
      <header className="app-header">
        <div>
          <h1>Complete-Set Internalization Hook</h1>
          <p className="subtle">CTF complete-set backstop for a YES/NO Uniswap v4 pool</p>
        </div>
        <WalletBar demoTrader={deployment?.demoTrader} />
      </header>

      {deployment && deployment.chainId !== targetChain.id && (
        <p className="warn banner">
          This frontend targets chain {targetChain.id}, but deployment.json belongs to chain {deployment.chainId}.
        </p>
      )}

      {isConnected && chainId !== targetChain.id && (
        <div className="warn banner network-banner" role="alert">
          <span>
            Connected wallet is on chain {chainId}. Approve the request to switch to {targetChain.name}.
          </span>
          <button
            type="button"
            className="btn btn-ghost"
            disabled={isSwitchingNetwork}
            aria-busy={isSwitchingNetwork}
            onClick={() => void switchNetwork().catch(() => undefined)}
          >
            {isSwitchingNetwork ? "Switching…" : `Switch to ${targetChain.name}`}
          </button>
        </div>
      )}

      {isLoading && <p className="subtle">Loading deployment…</p>}
      {error && (
        <p className="warn banner">
          {error instanceof Error ? error.message : "Failed to load deployment.json"} — run{" "}
          <code>forge script script/00_DeployCompleteSetInternalizationHook.s.sol --broadcast</code> against {" "}
          {targetChain.name} first.
        </p>
      )}

      {deployment && poolId && (
        <main className="grid">
          <MarketPanel deployment={deployment} poolId={poolId} />
          <SwapPanel deployment={deployment} />
          <LiquidityPanel deployment={deployment} poolId={poolId} />
          <MergePanel deployment={deployment} />
        </main>
      )}
    </div>
  );
}

export default App;
