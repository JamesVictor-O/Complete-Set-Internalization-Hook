import { encodeAbiParameters, keccak256, type Hex } from "viem";
import type { PoolKeyJson } from "./deployment";

/// Mirrors Uniswap v4's `PoolIdLibrary.toId`: `keccak256(abi.encode(poolKey))` over the struct's five
/// fields in declaration order. `PoolKey` has no dynamic members, so this is exactly what Solidity's
/// `abi.encode` of the struct itself would produce — there is no separate on-chain call needed to
/// resolve which pool a `deployment.json` `poolKey` refers to.
export function computePoolId(poolKey: PoolKeyJson): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "uint24" },
        { type: "int24" },
        { type: "address" },
      ],
      [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
    ),
  );
}
