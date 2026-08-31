import { defineChain } from "viem";

/// Local development remains available by setting VITE_TARGET_CHAIN_ID=31337.
export const anvilLocal = defineChain({
  id: 31337,
  name: "Anvil Local",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
});

export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Unichain Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://sepolia.unichain.org"] },
  },
  blockExplorers: {
    default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" },
  },
  testnet: true,
});

// The checked-in deployment is live on Unichain Sepolia, so plain `npm run dev` targets it too.
const configuredChainId = Number(import.meta.env.VITE_TARGET_CHAIN_ID ?? unichainSepolia.id);

if (configuredChainId !== anvilLocal.id && configuredChainId !== unichainSepolia.id) {
  throw new Error(`Unsupported VITE_TARGET_CHAIN_ID: ${configuredChainId}`);
}

export const targetChain = configuredChainId === unichainSepolia.id ? unichainSepolia : anvilLocal;
