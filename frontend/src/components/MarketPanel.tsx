import type { Hex } from "viem";
import type { Deployment, PoolKeyJson } from "../config/deployment";
import { useAmmLiquidity, useMarket } from "../hooks/useMarket";
import { useQuote } from "../hooks/useQuote";
import { formatToken, shortAddress } from "../lib/format";

const PROBE_AMOUNT = 1_000_000_000_000_000_000n; // 1 token, just to read a live AMM price sample

export function MarketPanel({ deployment, poolId, poolKey }: { deployment: Deployment; poolId: Hex; poolKey: PoolKeyJson }) {
  const { data: m, isLoading } = useMarket(deployment.hook, deployment.marketId);
  const collateralForOutcome = poolKey.currency0.toLowerCase() === deployment.collateralToken.toLowerCase();
  const { data: probeQuote } = useQuote(deployment.quoter, poolKey, collateralForOutcome, PROBE_AMOUNT);
  const {
    data: ammLiquidity,
    isLoading: isAmmLiquidityLoading,
    isError: isAmmLiquidityError,
  } = useAmmLiquidity(poolId);

  const ammLiquidityValue = isAmmLiquidityLoading
    ? "Loading…"
    : isAmmLiquidityError || ammLiquidity === undefined
      ? "Unavailable"
      : `${formatToken(ammLiquidity)} liquidity units`;

  return (
    <section className="panel">
      <h2>{deployment.marketQuestion}</h2>
      <p className="subtle">
        YES <code>{shortAddress(deployment.yesToken)}</code> / NO <code>{shortAddress(deployment.noToken)}</code>
      </p>

      {isLoading || !m ? (
        <p className="subtle">Loading market…</p>
      ) : !m.registered ? (
        <p className="warn">This pool has no market registered against this hook.</p>
      ) : (
        <div className="stat-grid">
          <Stat label="Free reserve collateral" value={`${formatToken(m.freeCollateral)} dUSD`} />
          <Stat label="Uniswap AMM active liquidity" value={ammLiquidityValue} />
          <Stat label="YES inventory" value={formatToken(m.yesInventory)} />
          <Stat label="NO inventory" value={formatToken(m.noInventory)} />
          <Stat label="Pending dUSD settlement" value={`${formatToken(m.pendingCollateralClaims)} dUSD`} />
          <Stat label="Total LP shares" value={formatToken(m.totalShares)} />
          <Stat label="Lifetime surplus" value={`${formatToken(m.lifetimeSurplus)} dUSD`} />
          <Stat
            label="Sample AMM output (1 dUSD input)"
            value={probeQuote?.ammQuote.available ? `${formatToken(probeQuote.ammQuote.amount)} outcome` : "—"}
          />
          <Stat label="Status" value={m.frozen ? "Frozen (resolved)" : "Active"} />
        </div>
      )}
    </section>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">{value}</span>
    </div>
  );
}
