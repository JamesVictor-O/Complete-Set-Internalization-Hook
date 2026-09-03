import { useMemo, useState } from "react";
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
  const [selectedOutcome, setSelectedOutcome] = useState<"YES" | "NO">("YES");
  const poolKey = deployment ? (selectedOutcome === "YES" ? deployment.yesPoolKey : deployment.noPoolKey) : undefined;
  const poolId = useMemo(() => (poolKey ? computePoolId(poolKey) : undefined), [poolKey]);

  return (
    <div className="app">
      <header className="app-header">
        <div>
          <h1>Complete-Set Internalization Hook</h1>
          <p className="subtle">Executable complete-set liquidity across YES/dUSD and NO/dUSD Uniswap v4 pools</p>
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

      {deployment && poolId && poolKey && (
        <>
          <div className="button-row" aria-label="Select outcome market">
            <button className={selectedOutcome === "YES" ? "btn btn-primary" : "btn btn-ghost"} onClick={() => setSelectedOutcome("YES")}>YES / dUSD</button>
            <button className={selectedOutcome === "NO" ? "btn btn-primary" : "btn btn-ghost"} onClick={() => setSelectedOutcome("NO")}>NO / dUSD</button>
          </div>
          <main className="grid">
            <MarketPanel deployment={deployment} poolId={poolId} poolKey={poolKey} />
            <SwapPanel deployment={deployment} poolKey={poolKey} outcome={selectedOutcome} />
            <LiquidityPanel deployment={deployment} />
            <MergePanel deployment={deployment} />
          </main>
        </>
      )}
    </div>
  );
}

export default App;
