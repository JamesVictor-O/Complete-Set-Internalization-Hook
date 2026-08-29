import { useMemo } from "react";
import { useAccount } from "wagmi";
import { useDeployment } from "./hooks/useDeployment";
import { computePoolId } from "./config/poolId";
import { anvilLocal } from "./config/chain";
import { WalletBar } from "./components/WalletBar";
import { MarketPanel } from "./components/MarketPanel";
import { SwapPanel } from "./components/SwapPanel";
import { LiquidityPanel } from "./components/LiquidityPanel";
import { MergePanel } from "./components/MergePanel";
import "./App.css";

function App() {
  const { data: deployment, isLoading, error } = useDeployment();
  const { chainId, isConnected } = useAccount();
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

      {isConnected && chainId !== anvilLocal.id && (
        <p className="warn banner">
          Connected wallet is on chain {chainId}, but this demo only talks to local Anvil (chain{" "}
          {anvilLocal.id}).
        </p>
      )}

      {isLoading && <p className="subtle">Loading deployment…</p>}
      {error && (
        <p className="warn banner">
          {error instanceof Error ? error.message : "Failed to load deployment.json"} — run{" "}
          <code>forge script script/00_DeployCompleteSetInternalizationHook.s.sol --broadcast</code> against a
          local Anvil node first.
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
