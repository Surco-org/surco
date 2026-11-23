import assert from "node:assert/strict"
import test from "node:test"
import { backing, chirpDollars, formatUsd, marketCap, usdLine } from "./market.js"
import { onLive, refreshLive } from "./live.js"

test("small dollar prices keep their digits", () => {
  assert.equal(formatUsd(0.000321), "$0.000321")
  assert.equal(formatUsd(0.032), "$0.032")
  assert.equal(formatUsd(1.2), "$1.20")
  assert.equal(formatUsd(0.0003), "$0.0003")
  assert.equal(formatUsd(0), null)
  assert.equal(formatUsd(Number.NaN), null)
})

test("the open dollar line uses Pinto's price", () => {
  assert.equal(
    usdLine("0.01", 0.032),
    "Opens near $0.00032. That is 0.01 Pinto, and Pinto is $0.032 right now.",
  )
  assert.equal(usdLine("0.01", null), null)
  assert.equal(chirpDollars("0.01", 0.0326), "$0.000326")
  assert.equal(chirpDollars("0.01", null), null)
})

test("the feed hands every subscriber the body, and null when it fails", async () => {
  const seen = []
  onLive((snap) => seen.push(snap?.book ?? null))
  await refreshLive(async () => ({ ok: true, json: async () => ({ book: "0xb", series: [] }) }))
  await refreshLive(async () => ({ ok: false, status: 503 }))
  await refreshLive(async () => { throw new Error("down") })
  assert.deepEqual(seen, ["0xb", null, null])
  // A late subscriber still gets the last good body at once.
  let late
  onLive((snap) => (late = snap.book))
  assert.equal(late, "0xb")
})

test("one subscriber that throws does not starve the rest", async () => {
  const seen = []
  assert.doesNotThrow(() => onLive(() => { throw new Error("chart broke") }))
  onLive((snap) => seen.push(snap?.book ?? null))
  await refreshLive(async () => ({ ok: true, json: async () => ({ book: "0xc", series: [] }) }))
  assert.deepEqual(seen, ["0xb", "0xc"])
})

test("market cap is the dollar price times the live supply", () => {
  assert.equal(marketCap(0.00018757, "1000000000000000000000000000"), "$187,570")
  assert.equal(marketCap(0.00018757, "500000000000000000000000000"), "$93,785")
  assert.equal(marketCap(0, "1000000000000000000000000000"), null)
  assert.equal(marketCap(0.0002, undefined), null)
})

test("backing is the silo Pinto and its dollar value", () => {
  assert.equal(backing("1414589903", 0.01909243), "1,415 Pinto · $27")
  assert.equal(backing("1414589903", null), "1,415 Pinto")
  assert.equal(backing("0", 1), null)
  assert.equal(backing(undefined, 1), null)
})
