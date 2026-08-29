import type { Address } from "viem";
import { useAppWallet } from "../hooks/useAppWallet";
import { shortAddress } from "../lib/format";

export function WalletBar({ demoTrader }: { demoTrader: Address | undefined }) {
  const { mode, address, isConnected, connectInjected, connectDemo, disconnect } = useAppWallet();

  if (isConnected) {
    return (
      <div className="wallet-bar">
        <span className={`mode-badge mode-${mode}`}>{mode === "demo" ? "Demo trader" : "Wallet"}</span>
        <span className="address">{shortAddress(address)}</span>
        <button type="button" className="btn btn-ghost" onClick={disconnect}>
          Disconnect
        </button>
      </div>
    );
  }

  return (
    <div className="wallet-bar">
      <button type="button" className="btn btn-primary" onClick={connectInjected}>
        Connect wallet
      </button>
      <button
        type="button"
        className="btn btn-ghost"
        disabled={!demoTrader}
        onClick={() => demoTrader && connectDemo(demoTrader)}
        title="Uses the local Anvil demo account the deploy script pre-funded with YES/NO tokens"
      >
        Use demo trader
      </button>
    </div>
  );
}
