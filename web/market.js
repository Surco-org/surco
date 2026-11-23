// The live Chirp and Pinto dollar figures and the market cap, from the shared /api/chirp feed (live.js). The worker prices Pinto as what 100 Pinto sells for in Pinto's USDC
// well and keeps every reading in D1. A failed read stays a sentence. It never becomes a guessed number.

import { onLive } from "./live.js"

export function formatUsd(n) {
  if (!(typeof n === "number") || !Number.isFinite(n) || n <= 0) return null
  if (n >= 1) return "$" + n.toFixed(2)
  const digits = Math.min(8, Math.max(2, Math.ceil(-Math.log10(n)) + 2))
  const text = n.toFixed(digits).replace(/0+$/, "").replace(/\.$/, "")
  return "$" + text
}

export function chirpDollars(label, pintoUsd) {
  const chirpPx = Number(String(label).replace(/,/g, ""))
  if (!(chirpPx > 0) || !(pintoUsd > 0)) return null
  return formatUsd(chirpPx * pintoUsd)
}

/** Chirp's dollar price × its live totalSupply (18 decimals; buybacks burn, so it only falls). */
export function marketCap(chirpUsd, supplyRaw) {
  const n = chirpUsd * (Number(BigInt(supplyRaw ?? 0) / 10n ** 12n) / 1e6)
  return n > 0 ? "$" + Math.round(n).toLocaleString("en-US") : null
}

/** Pinto deposited in the silo for the book (6 decimals), with its dollar value: the real money behind the cap. */
export function backing(siloRaw, pintoUsd) {
  const pinto = Number(BigInt(siloRaw ?? 0)) / 1e6
  if (!(pinto > 0)) return null
  const p = Math.round(pinto).toLocaleString("en-US") + " Pinto"
  return pintoUsd > 0 ? `${p} · $${Math.round(pinto * pintoUsd).toLocaleString("en-US")}` : p
}

export function usdLine(label, pintoUsd) {
  const dollars = chirpDollars(label, pintoUsd)
  const pinto = formatUsd(pintoUsd)
  if (!dollars || !pinto) return null
  const lead = label === "0.01" ? "Opens near" : "About"
  return `${lead} ${dollars}. That is ${label} Pinto, and Pinto is ${pinto} right now.`
}

function boot() {
  const usd = document.querySelector("#usd")
  const mkt = document.querySelector("#mkt-price")
  const price = document.querySelector("#price")
  const heroUsd = document.querySelector("#hero-usd")
  const heroCap = document.querySelector("#hero-cap")
  const heroBacking = document.querySelector("#hero-backing")
  if (!usd || !mkt) return
  let pintoUsd = null
  const render = () => {
    if (pintoUsd == null) return
    const label = mkt.textContent.trim()
    const line = usdLine(label, pintoUsd)
    if (line) usd.textContent = line
    const dollars = chirpDollars(label, pintoUsd)
    if (heroUsd && dollars) heroUsd.textContent = dollars
  }
  const copy = () => {
    if (price) mkt.textContent = price.textContent
    render()
  }
  copy()
  if (price) new MutationObserver(copy).observe(price, { childList: true, characterData: true, subtree: true })
  onLive((snap) => {
    if (!snap) return
    pintoUsd = snap.pintoUsd
    render()
    const cap = marketCap(snap.chirpUsd, snap.field?.supply)
    if (heroCap && cap) heroCap.textContent = cap
    const back = backing(snap.field?.silo, snap.pintoUsd)
    if (heroBacking && back) heroBacking.textContent = back
  })
}

if (typeof document !== "undefined") boot()
