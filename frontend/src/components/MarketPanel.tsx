import type { Hex } from "viem";
import type { Deployment } from "../config/deployment";
import { useMarket } from "../hooks/useMarket";
import { useQuote } from "../hooks/useQuote";
import { formatToken, formatWadPrice, shortAddress } from "../lib/format";

const PROBE_AMOUNT = 1_000_000_000_000_000_000n; // 1 token, just to read a live AMM price sample

export function MarketPanel({ deployment, poolId }: { deployment: Deployment; poolId: Hex }) {
  const { data: m, isLoading } = useMarket(deployment.hook, poolId);
  const { data: probeQuote } = useQuote(deployment.quoter, deployment.poolKey, true, PROBE_AMOUNT);

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
          <Stat label="LP reserve (collateral)" value={`${formatToken(m.collateralReserve)} dUSD`} />
          <Stat label="YES inventory" value={formatToken(m.yesInventory)} />
          <Stat label="NO inventory" value={formatToken(m.noInventory)} />
          <Stat label="Pending YES claims" value={formatToken(m.yesClaimBalance)} />
          <Stat label="Pending NO claims" value={formatToken(m.noClaimBalance)} />
          <Stat label="Total LP shares" value={formatToken(m.totalShares)} />
          <Stat label="Lifetime surplus" value={`${formatToken(m.lifetimeSurplus)} dUSD`} />
          <Stat
            label="Sample AMM price (1 unit)"
            value={probeQuote?.ammQuote.available ? formatWadPrice(probeQuote.ammQuote.effectivePriceWad) : "—"}
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
