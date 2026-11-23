import { test } from "node:test"
import assert from "node:assert/strict"
import { pintoStatus } from "./pinto.js"

const live = {
  pintoUsd: 0.01909243,
  field: { temp: "4989000000", maxTemp: "4989000000", soil: "270657200", earned: "0", below: true },
}

test("live snapshot: price, gap to $1, temperature as a percent, soil and yield in Pinto", () => {
  assert.deepEqual(pintoStatus(live), {
    price: "$0.0191", gap: "about 52× below $1", temp: "4,989%", maxTemp: "4,989%",
    soil: "270.66 Pinto", earned: "0 Pinto", below: true,
  })
})

test("no feed: every figure is a dash, never a guess", () => {
  for (const snap of [null, undefined, {}, { field: {} }]) {
    assert.deepEqual(pintoStatus(snap), { price: "—", gap: "—", temp: "—", maxTemp: "—", soil: "—", earned: "—", below: null })
  }
})

test("above peg the gap says so", () => {
  assert.equal(pintoStatus({ pintoUsd: 1.02, field: { below: false } }).gap, "above $1")
})

test("close under $1 the gap is a percent, not a multiple", () => {
  assert.equal(pintoStatus({ pintoUsd: 0.97, field: { below: true } }).gap, "3% below $1")
})

test("the gap follows the price shown, not the peg flag, and never reads 0% or negative", () => {
  assert.equal(pintoStatus({ pintoUsd: 1.01, field: { below: true } }).gap, "above $1")
  assert.equal(pintoStatus({ pintoUsd: 0.97, field: { below: false } }).gap, "3% below $1")
  assert.equal(pintoStatus({ pintoUsd: 0.998, field: { below: true } }).gap, "less than 1% below $1")
  assert.equal(pintoStatus({ pintoUsd: 1, field: {} }).gap, "at $1")
})
