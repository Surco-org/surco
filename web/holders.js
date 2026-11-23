// /chirp holders table: top 100 from /api/chirp/holders, share of the live supply (burns lower it).
import { formatAmount } from "./quote.js"
import { onLive } from "./live.js"
import { label, linkCell, scan, short, textCell } from "./labels.js"

export function holderRow(h, supply, rank) {
  const bal = BigInt(h.bal)
  const known = label(h.addr)
  const bps = supply > 0n ? (bal * 1_000_000n) / supply : 0n // 1e-4 %
  return {
    rank,
    who: known?.name ?? short(h.addr),
    tag: known?.tag,
    href: scan("address", h.addr),
    chirp: formatAmount(bal, 18, 1),
    pct: `${(Number(bps) / 10_000).toFixed(2)}%`,
  }
}

function boot() {
  const body = document.querySelector("#holders tbody")
  const count = document.querySelector("#holder-count")
  if (!body) return
  let seen = null
  onLive(async (snap) => {
    const n = snap?.usage?.holders
    const supply = snap?.field?.supply
    if (n === undefined || !supply) return
    const k = `${n}:${supply}:${snap.usage.tradesAll}`
    if (k === seen) return
    seen = k
    try {
      const res = await fetch("/api/chirp/holders")
      if (!res.ok) return
      const data = await res.json()
      count.textContent = data.count ? `${data.count.toLocaleString("en-US")} wallets hold Chirp.` : "No holders yet."
      body.replaceChildren(...data.rows.map((h, i) => {
        const r = holderRow(h, BigInt(supply), i + 1)
        const tr = document.createElement("tr")
        tr.append(textCell(String(r.rank), "num"), linkCell(r.who, r.href, r.tag), textCell(r.chirp, "num"), textCell(r.pct, "num"))
        return tr
      }))
    } catch {}
  })
}

if (typeof document !== "undefined") boot()
