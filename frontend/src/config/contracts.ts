import type { Abi } from "viem";

import hookAbiJson from "../abi/CompleteSetInternalizationHook.json";
import quoterAbiJson from "../abi/CompleteSetQuoter.json";
import routerAbiJson from "../abi/IUniswapV4Router04.json";
import { stateViewAbi } from "../abi/stateView";

export const hookAbi = hookAbiJson as Abi;
export const quoterAbi = quoterAbiJson as Abi;
export const routerAbi = routerAbiJson as Abi;
export { stateViewAbi };

export { erc20Abi } from "../abi/erc20";
