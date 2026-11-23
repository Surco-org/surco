import { test } from "node:test"
import assert from "node:assert/strict"
import {
  OPENING,
  applySlippage,
  buyFeeBps,
  formatAmount,
  formatFee,
  parseAmount,
  bookAfterBuy,
  pathEnd,
  priceRaw,
  quoteBuy,
  quoteSell,
} from "./quote.js"

const DEV = 1_000n * 1_000_000n

test("opening price is 0.01 Pinto", () => {
  assert.equal(priceRaw(OPENING), 10_000n)
  assert.equal(formatAmount(priceRaw(OPENING), 6, 6), "0.01")
})

test("a 1,000 Pinto launch buy at 1% matches the book", () => {
  const q = quoteBuy(OPENING, DEV, 0n)
  assert.equal(q.feeBps, 100n)
  assert.equal(q.chirpOut, 98_990_199_970_202_949_907_959n)
  assert.equal(formatAmount(q.chirpOut, 18, 4), "98,990.2")
})

test("the price path rises as Pinto is paid in", () => {
  const book = bookAfterBuy(OPENING, DEV, 100n)
  assert.equal(book.pintoInCurve, DEV)
  assert.equal(book.chirpReserve, OPENING.chirpReserve - 98_990_199_970_202_949_907_959n)
  assert.equal(priceRaw(book), 10_001n)
  const later = pathEnd(5_000_000n * 1_000_000n, 40, 100n)
  const mid = pathEnd(1_000_000n * 1_000_000n, 40, 100n)
  assert.ok(later > mid)
  assert.ok(mid > 10_000n)
})

test("one Chirp sold after that buy pays 0.0099 Pinto", () => {
  const bought = quoteBuy(OPENING, DEV, 0n).chirpOut
  const book = {
    ...OPENING,
    pintoInCurve: DEV,
    chirpReserve: OPENING.chirpReserve - bought,
  }
  const sold = quoteSell(book, 10n ** 18n)
  assert.equal(sold.ok, true)
  assert.equal(sold.paid, 9_900n)
  assert.equal(formatAmount(sold.paid, 6, 6), "0.0099")
})

test("a sell before any buy is refused", () => {
  assert.equal(quoteSell(OPENING, 10n ** 18n).reason, "empty")
})

test("the toll falls in a straight line for ten minutes", () => {
  const start = 1_000n
  assert.equal(buyFeeBps(0n, start), 100n)
  assert.equal(buyFeeBps(start, start), 9_000n)
  assert.equal(buyFeeBps(start, start + 300n), 4_550n)
  assert.equal(buyFeeBps(start, start + 599n), 115n)
  assert.equal(buyFeeBps(start, start + 600n), 100n)
  assert.equal(formatFee(9_000n), "90%")
  assert.equal(formatFee(4_550n), "45.5%")
  assert.equal(formatFee(115n), "1.15%")
  assert.equal(formatFee(100n), "1%")
})

test("amounts parse and slippage floors the minimum", () => {
  assert.equal(parseAmount("1000", 6), DEV)
  assert.equal(parseAmount("0.0099", 6), 9_900n)
  assert.equal(parseAmount("1.0000001", 6), null)
  assert.equal(parseAmount("", 6), null)
  assert.equal(applySlippage(1_000n, 100), 990n)
})
