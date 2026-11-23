// Integer quotes for the Chirp book. Same truncating division as the contract.

export const BPS = 10_000n
export const FEE_BPS = 100n
export const TOLL_START_BPS = 9_000n
export const TOLL_WINDOW = 600n

export const OPENING = {
  virtualPinto: 10_000_000n * 1_000_000n,
  pintoInCurve: 0n,
  chirpReserve: 1_000_000_000n * 10n ** 18n,
  tollStart: 0n,
}

export function buyFeeBps(tollStart, now) {
  if (tollStart === 0n) return FEE_BPS
  const elapsed = now - tollStart
  if (elapsed >= TOLL_WINDOW) return FEE_BPS
  return TOLL_START_BPS - ((TOLL_START_BPS - FEE_BPS) * elapsed) / TOLL_WINDOW
}

export function quoteBuy(book, pintoIn, now) {
  const feeBps = buyFeeBps(book.tollStart, now)
  const traded = (pintoIn * (BPS - feeBps)) / BPS
  if (traded === 0n || book.chirpReserve === 0n) return { feeBps, chirpOut: 0n }
  const chirpOut = (book.chirpReserve * traded) / (book.virtualPinto + book.pintoInCurve + traded)
  return { feeBps, chirpOut }
}

export function quoteSell(book, chirpIn) {
  const gross = ((book.virtualPinto + book.pintoInCurve) * chirpIn) / (book.chirpReserve + chirpIn)
  if (gross === 0n) return { ok: false, reason: "small" }
  if (gross > book.pintoInCurve) return { ok: false, reason: book.pintoInCurve === 0n ? "empty" : "big" }
  const paid = (gross * (BPS - FEE_BPS)) / BPS
  return { ok: true, paid }
}

export function priceRaw(book) {
  if (book.chirpReserve === 0n) return 0n
  return ((book.virtualPinto + book.pintoInCurve) * 10n ** 18n) / book.chirpReserve
}

// The book after one buy. The full payment joins the price. Only the part
// after the fee buys Chirp.
export function bookAfterBuy(book, pintoIn, feeBps) {
  const traded = (pintoIn * (BPS - feeBps)) / BPS
  let chirpOut = 0n
  if (traded !== 0n && book.chirpReserve !== 0n) {
    chirpOut = (book.chirpReserve * traded) / (book.virtualPinto + book.pintoInCurve + traded)
  }
  return {
    virtualPinto: book.virtualPinto,
    pintoInCurve: book.pintoInCurve + pintoIn,
    chirpReserve: book.chirpReserve - chirpOut,
    tollStart: book.tollStart,
  }
}

// Spot price after `steps` equal buys that add up to `totalPinto`, at one fee.
export function pathEnd(totalPinto, steps, feeBps = FEE_BPS) {
  let book = OPENING
  const chunk = totalPinto / BigInt(steps)
  let left = totalPinto
  for (let i = 0; i < steps; i++) {
    const pay = i === steps - 1 ? left : chunk
    book = bookAfterBuy(book, pay, feeBps)
    left -= pay
  }
  return priceRaw(book)
}

export function applySlippage(amount, bps) {
  return (amount * (BPS - BigInt(bps))) / BPS
}

export function parseAmount(text, decimals) {
  const s = String(text).trim()
  if (!/^\d+(\.\d+)?$/.test(s)) return null
  const [whole, frac = ""] = s.split(".")
  if (frac.length > decimals) return null
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0") || "0")
}

export function formatAmount(amount, decimals, maxFrac = 4) {
  if (amount === 0n) return "0"
  const sign = amount < 0n ? "-" : ""
  let v = amount < 0n ? -amount : amount
  const scale = 10n ** BigInt(decimals)
  let whole = v / scale
  const frac = v % scale
  if (maxFrac <= 0 || frac === 0n) return sign + group(whole)
  const keep = Math.min(maxFrac, decimals)
  const cut = 10n ** BigInt(decimals - keep)
  let digits = frac / cut
  const rest = frac % cut
  if (rest * 2n >= cut) digits += 1n
  const limit = 10n ** BigInt(keep)
  if (digits >= limit) {
    whole += 1n
    digits = 0n
  }
  const fracStr = digits.toString().padStart(keep, "0").replace(/0+$/, "")
  return sign + group(whole) + (fracStr ? `.${fracStr}` : "")
}

function group(whole) {
  return whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

export function formatFee(bps) {
  const whole = bps / 100n
  const frac = bps % 100n
  if (frac === 0n) return `${whole}%`
  const text = frac.toString().padStart(2, "0").replace(/0$/, "")
  return `${whole}.${text}%`
}
