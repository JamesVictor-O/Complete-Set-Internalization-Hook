import type { Address } from "viem";
import { useAppWallet } from "../hooks/useAppWallet";
import { shortAddress } from "../lib/format";
import { targetChain, anvilLocal } from "../config/chain";

export function WalletBar({ demoTrader }: { demoTrader: Address | undefined }) {
  const { mode, address, isConnected, connectInjected, connectDemo, disconnect, networkError } = useAppWallet();

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
    <div>
      <div className="wallet-bar">
        <button type="button" className="btn btn-primary" onClick={() => void connectInjected()}>
          Connect wallet
        </button>
        <button
          type="button"
          className="btn btn-ghost"
          disabled={!demoTrader || targetChain.id !== anvilLocal.id}
          onClick={() => demoTrader && connectDemo(demoTrader)}
          title={
            targetChain.id === anvilLocal.id
              ? "Uses the local Anvil demo account pre-funded with YES/NO tokens"
              : "Demo trader mode is only available on local Anvil; connect a wallet on testnet"
          }
        >
          Use demo trader
        </button>
      </div>
      {networkError && <p className="wallet-error" role="alert">{networkError}</p>}
    </div>
  );
}
