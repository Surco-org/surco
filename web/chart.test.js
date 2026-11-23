import assert from "node:assert/strict"
import test from "node:test"
import { badge, changePct, priceText, toSeries, windowRows } from "./chart-model.js"

test("toSeries: usd plots chirpUsd, pinto plots chirp/pinto", () => {
  assert.deepEqual(toSeries([[1, 0.02, 0.0002]], "usd"), [{ time: 1, value: 0.0002 }])
  const [p] = toSeries([[1, 0.02, 0.0002]], "pinto")
  assert.equal(p.time, 1)
  assert.ok(Math.abs(p.value - 0.01) < 1e-12)
})

test("toSeries: strictly increasing time — a repeat t replaces, an older t drops", () => {
  const s = toSeries([[1, 1, 1], [2, 1, 2], [2, 1, 3], [1, 1, 9], [3, 1, 4]], "usd")
  assert.deepEqual(s, [{ time: 1, value: 1 }, { time: 2, value: 3 }, { time: 3, value: 4 }])
})

test("toSeries: pinto mode skips rows with non-positive pintoUsd; non-positive values skipped", () => {
  assert.deepEqual(toSeries([[1, 0, 1], [2, -1, 1], [3, 2, 1]], "pinto"), [{ time: 3, value: 0.5 }])
  assert.deepEqual(toSeries([[1, 1, 0], [2, 1, 5]], "usd"), [{ time: 2, value: 5 }])
})

test("changePct: from first to last; 0 for fewer than 2 points", () => {
  assert.equal(changePct([]), 0)
  assert.equal(changePct([{ time: 1, value: 2 }]), 0)
  assert.equal(changePct([{ time: 1, value: 2 }, { time: 2, value: 3 }]), 50)
})

test("badge: up / down / flat", () => {
  assert.deepEqual(badge(1.234), { text: "+1.23%", dir: "up" })
  assert.deepEqual(badge(-0.4), { text: "−0.40%", dir: "down" })
  assert.deepEqual(badge(0.001), { text: "0.00%", dir: "flat" })
  assert.deepEqual(badge(-0.001), { text: "0.00%", dir: "flat" })
})

test("priceText: usd to 4 significant figures, pinto to 6 decimals", () => {
  assert.equal(priceText(0.00018968, "usd"), "$0.0001897")
  assert.equal(priceText(0.000123, "usd"), "$0.0001230")
  assert.equal(priceText(2.5, "usd"), "$2.50")
  assert.equal(priceText(0, "usd"), "—")
  assert.equal(priceText(0.0123456789, "pinto"), "0.012346 Pinto")
})

test("windowRows: keeps rows from `from`, the last older row moved to `from` as the baseline", () => {
  const rows = [[1, 1, 1], [5, 1, 2], [20, 1, 3], [30, 1, 4]]
  assert.deepEqual(windowRows(rows, 10), [[10, 1, 2], [20, 1, 3], [30, 1, 4]])
  assert.deepEqual(windowRows(rows, 0), rows)
  assert.deepEqual(windowRows([[1, 1, 1]], 10), [[10, 1, 1]])
})
