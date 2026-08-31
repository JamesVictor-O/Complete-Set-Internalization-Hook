import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { anvilLocal, targetChain, unichainSepolia } from "./chain";

const chains =
  targetChain.id === unichainSepolia.id
    ? ([unichainSepolia, anvilLocal] as const)
    : ([anvilLocal, unichainSepolia] as const);

export const wagmiConfig = createConfig({
  chains,
  connectors: [injected()],
  transports: {
    [anvilLocal.id]: http(),
    [unichainSepolia.id]: http(),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
