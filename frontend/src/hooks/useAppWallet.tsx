import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { useAccount, useConnect, useDisconnect, useWriteContract } from "wagmi";
import { injected } from "wagmi/connectors";
import type { Abi, Address, Hash } from "viem";
import { createDemoTraderClient, type DemoTraderClient } from "../config/demoTrader";

export type WalletMode = "injected" | "demo" | null;

interface WriteArgs {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
}

interface AppWalletContextValue {
  mode: WalletMode;
  address: Address | undefined;
  isConnected: boolean;
  connectInjected: () => void;
  connectDemo: (address: Address) => void;
  disconnect: () => void;
  writeContract: (args: WriteArgs) => Promise<Hash>;
  isWriting: boolean;
}

const AppWalletContext = createContext<AppWalletContextValue | null>(null);

export function AppWalletProvider({ children }: { children: ReactNode }) {
  const { address: injectedAddress, isConnected: injectedConnected } = useAccount();
  const { connect } = useConnect();
  const { disconnect: disconnectInjected } = useDisconnect();
  const { writeContractAsync, isPending: isInjectedWriting } = useWriteContract();

  const [demoAddress, setDemoAddress] = useState<Address | undefined>();
  const [demoClient, setDemoClient] = useState<DemoTraderClient | undefined>();
  const [isDemoWriting, setIsDemoWriting] = useState(false);

  const mode: WalletMode = injectedConnected ? "injected" : demoAddress ? "demo" : null;
  const address = injectedConnected ? injectedAddress : demoAddress;

  const connectInjected = useCallback(() => {
    setDemoAddress(undefined);
    setDemoClient(undefined);
    connect({ connector: injected() });
  }, [connect]);

  const connectDemo = useCallback((traderAddress: Address) => {
    setDemoAddress(traderAddress);
    setDemoClient(createDemoTraderClient(traderAddress));
  }, []);

  const disconnect = useCallback(() => {
    if (injectedConnected) disconnectInjected();
    setDemoAddress(undefined);
    setDemoClient(undefined);
  }, [injectedConnected, disconnectInjected]);

  const writeContract = useCallback(
    async (args: WriteArgs): Promise<Hash> => {
      if (mode === "injected") {
        return writeContractAsync(args);
      }
      if (mode === "demo" && demoClient) {
        setIsDemoWriting(true);
        try {
          return await demoClient.writeContract(args);
        } finally {
          setIsDemoWriting(false);
        }
      }
      throw new Error("No wallet connected");
    },
    [mode, demoClient, writeContractAsync],
  );

  const value = useMemo<AppWalletContextValue>(
    () => ({
      mode,
      address,
      isConnected: mode !== null,
      connectInjected,
      connectDemo,
      disconnect,
      writeContract,
      isWriting: mode === "injected" ? isInjectedWriting : isDemoWriting,
    }),
    [mode, address, connectInjected, connectDemo, disconnect, writeContract, isInjectedWriting, isDemoWriting],
  );

  return <AppWalletContext.Provider value={value}>{children}</AppWalletContext.Provider>;
}

export function useAppWallet(): AppWalletContextValue {
  const ctx = useContext(AppWalletContext);
  if (!ctx) throw new Error("useAppWallet must be used within AppWalletProvider");
  return ctx;
}
