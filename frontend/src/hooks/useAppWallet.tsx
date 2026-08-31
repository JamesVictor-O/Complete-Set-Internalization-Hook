import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain, useWriteContract } from "wagmi";
import { injected } from "wagmi/connectors";
import type { Abi, Address, Hash } from "viem";
import { createDemoTraderClient, type DemoTraderClient } from "../config/demoTrader";
import { targetChain } from "../config/chain";

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
  connectInjected: () => Promise<void>;
  switchNetwork: () => Promise<void>;
  isSwitchingNetwork: boolean;
  networkError: string | undefined;
  connectDemo: (address: Address) => void;
  disconnect: () => void;
  writeContract: (args: WriteArgs) => Promise<Hash>;
  isWriting: boolean;
}

const AppWalletContext = createContext<AppWalletContextValue | null>(null);

export function AppWalletProvider({ children }: { children: ReactNode }) {
  const { address: injectedAddress, chainId, isConnected: injectedConnected } = useAccount();
  const { connectAsync } = useConnect();
  const { disconnect: disconnectInjected } = useDisconnect();
  const { switchChainAsync, isPending: isSwitchingNetwork } = useSwitchChain();
  const { writeContractAsync, isPending: isInjectedWriting } = useWriteContract();

  const [demoAddress, setDemoAddress] = useState<Address | undefined>();
  const [demoClient, setDemoClient] = useState<DemoTraderClient | undefined>();
  const [isDemoWriting, setIsDemoWriting] = useState(false);
  const [networkError, setNetworkError] = useState<string>();
  const autoSwitchAttempt = useRef<number | undefined>(undefined);
  // Which mode the user actually picked, independent of wagmi's own reactive connector state. A
  // browser extension wallet can report itself connected (e.g. an auto-reconnect from a past site
  // visit) even when the user explicitly clicked "Use demo trader" here — without this, `mode` would
  // silently prefer that extension and route writes into it instead, where nothing is there to approve
  // them.
  const [selectedMode, setSelectedMode] = useState<WalletMode>(null);

  const mode: WalletMode =
    selectedMode === "injected" && injectedConnected
      ? "injected"
      : selectedMode === "demo" && demoAddress
        ? "demo"
        : null;
  const address = mode === "injected" ? injectedAddress : demoAddress;

  const switchNetwork = useCallback(async () => {
    setNetworkError(undefined);
    try {
      await switchChainAsync({ chainId: targetChain.id });
    } catch (error) {
      setNetworkError(error instanceof Error ? error.message : `Could not switch to ${targetChain.name}`);
      throw error;
    }
  }, [switchChainAsync]);

  const connectInjected = useCallback(async () => {
    setDemoAddress(undefined);
    setDemoClient(undefined);
    setSelectedMode("injected");
    setNetworkError(undefined);
    try {
      await connectAsync({ connector: injected(), chainId: targetChain.id });
    } catch (error) {
      setNetworkError(error instanceof Error ? error.message : "Could not connect wallet");
    }
  }, [connectAsync]);

  useEffect(() => {
    if (!injectedConnected || chainId === undefined || chainId === targetChain.id) return;
    if (autoSwitchAttempt.current === chainId) return;
    autoSwitchAttempt.current = chainId;
    void switchNetwork().catch(() => undefined);
  }, [chainId, injectedConnected, switchNetwork]);

  const connectDemo = useCallback((traderAddress: Address) => {
    setSelectedMode("demo");
    setDemoAddress(traderAddress);
    setDemoClient(createDemoTraderClient(traderAddress));
  }, []);

  const disconnect = useCallback(() => {
    if (injectedConnected) disconnectInjected();
    setDemoAddress(undefined);
    setDemoClient(undefined);
    setSelectedMode(null);
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
      switchNetwork,
      isSwitchingNetwork,
      networkError,
      connectDemo,
      disconnect,
      writeContract,
      isWriting: mode === "injected" ? isInjectedWriting : isDemoWriting,
    }),
    [mode, address, connectInjected, switchNetwork, isSwitchingNetwork, networkError, connectDemo, disconnect, writeContract, isInjectedWriting, isDemoWriting],
  );

  return <AppWalletContext.Provider value={value}>{children}</AppWalletContext.Provider>;
}

export function useAppWallet(): AppWalletContextValue {
  const ctx = useContext(AppWalletContext);
  if (!ctx) throw new Error("useAppWallet must be used within AppWalletProvider");
  return ctx;
}
