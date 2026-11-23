// Pure chart logic (no DOM, no chart library): rows from /api/chirp/history → a series lightweight-charts accepts.
import { formatUsd } from "./market.js"

/** rows: [t, pintoUsd, chirpUsd][]. Time strictly increases (the library throws otherwise): a repeated t
 *  replaces the previous value, an older t is dropped. Pinto mode = Chirp priced in Pinto. */
export function toSeries(rows, unit) {
  const out = []
  for (const [t, pinto, chirp] of rows) {
    if (unit === "pinto" && !(pinto > 0)) continue
    const value = unit === "pinto" ? chirp / pinto : chirp
    if (!(value > 0) || !Number.isFinite(value)) continue
    const last = out[out.length - 1]
    if (last && t < last.time) continue
    if (last && t === last.time) last.value = value
    else out.push({ time: t, value })
  }
  return out
}

export const changePct = (s) => (s.length < 2 ? 0 : ((s[s.length - 1].value - s[0].value) / s[0].value) * 100)

export function badge(pct) {
  if (!(Math.abs(pct) >= 0.005)) return { text: "0.00%", dir: "flat" }
  return pct > 0 ? { text: `+${pct.toFixed(2)}%`, dir: "up" } : { text: `−${(-pct).toFixed(2)}%`, dir: "down" }
}

/** Four significant figures under $1: formatUsd's two can't show a 2% move on a $0.00019 coin. */
export function priceText(v, unit) {
  if (unit === "pinto") return `${v.toFixed(6)} Pinto`
  if (!(v > 0)) return "—"
  return v >= 1 ? formatUsd(v) : "$" + v.toFixed(Math.min(10, Math.ceil(-Math.log10(v)) + 3))
}

/** Rows from `from` on; the last older row is kept as the baseline, moved to `from` so the line starts there. */
export function windowRows(rows, from) {
  let i = 0
  while (i < rows.length && rows[i][0] < from) i++
  return i === 0 ? rows : [[from, rows[i - 1][1], rows[i - 1][2]], ...rows.slice(i)]
}
