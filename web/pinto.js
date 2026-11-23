// The live Pinto figures on /pinto (the Editor's note), from the shared /api/chirp feed. A missing value is a dash.

import { onLive } from "./live.js"
import { formatUsd } from "./market.js"

const DASH = "—"
const big = (v) => {
  try {
    return v == null ? null : BigInt(v)
  } catch {
    return null
  }
}
// Pinto has 6 decimals; temperature is a percent with 6 decimals (4989000000 → 4,989%).
const pinto = (v) => (v == null ? DASH : (Number(v) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 2 }) + " Pinto")
const pct = (v) => (v == null ? DASH : Math.round(Number(v) / 1e6).toLocaleString("en-US") + "%")

// From the price shown beside it, so the two never disagree. `below` (all wells' deltaB) only toggles the note.
function gapTo1(p) {
  if (!(p > 0) || !Number.isFinite(p)) return DASH
  if (p > 1) return "above $1"
  if (p === 1) return "at $1"
  if (p < 0.5) return `about ${Math.round(1 / p)}× below $1`
  const pct = Math.round((1 - p) * 100)
  return pct < 1 ? "less than 1% below $1" : `${pct}% below $1`
}

export function pintoStatus(snap) {
  const f = snap?.field ?? {}
  const below = typeof f.below === "boolean" ? f.below : null
  return {
    price: formatUsd(snap?.pintoUsd) ?? DASH,
    gap: gapTo1(snap?.pintoUsd),
    temp: pct(big(f.temp)),
    maxTemp: pct(big(f.maxTemp)),
    soil: pinto(big(f.soil)),
    earned: pinto(big(f.earned)),
    below,
  }
}

function boot() {
  onLive((snap) => {
    if (!snap) return
    const s = pintoStatus(snap)
    for (const el of document.querySelectorAll("[data-live]")) el.textContent = s[el.dataset.live] ?? DASH
    for (const el of document.querySelectorAll("[data-when]")) el.hidden = s.below == null || (el.dataset.when === "below") !== s.below
  })
}

if (typeof document !== "undefined") boot()
