import { formatUnits } from "viem";

export function shortAddress(address: string | undefined): string {
  if (!address) return "";
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/// All tokens in this demo (collateral, wrapped YES, wrapped NO) are 18-decimal.
export function formatToken(amount: bigint | undefined, decimals = 4): string {
  if (amount === undefined) return "—";
  const value = Number(formatUnits(amount, 18));
  return value.toLocaleString(undefined, { maximumFractionDigits: decimals });
}

/// `CompleteSetQuoter` prices things as WAD fixed point ($1.00 == 1e18).
export function formatWadPrice(wad: bigint | undefined): string {
  if (wad === undefined) return "—";
  return `$${Number(formatUnits(wad, 18)).toFixed(4)}`;
}

export function formatBps(bps: bigint | undefined): string {
  if (bps === undefined) return "—";
  return `${(Number(bps) / 100).toFixed(2)}%`;
}
