import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { anvilLocal } from "./chain";

export const wagmiConfig = createConfig({
  chains: [anvilLocal],
  connectors: [injected()],
  transports: {
    [anvilLocal.id]: http(),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
