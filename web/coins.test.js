import { test } from "node:test"
import assert from "node:assert/strict"
import { ALLOWANCE_HOLDER, COINS, GAS_KEEP, maxSpend, parseZeroX, received, zeroX } from "./coins.js"

const firm = {
  buyAmount: "265698276",
  minBuyAmount: "263041293",
  transaction: { to: ALLOWANCE_HOLDER.toLowerCase(), data: "0xabcd", value: "0" },
  issues: { allowance: { spender: ALLOWANCE_HOLDER.toLowerCase() } },
}

test("a firm quote to the AllowanceHolder parses", () => {
  const q = parseZeroX(firm, true)
  assert.equal(q.minBuyAmount, 263041293n)
  assert.equal(q.data, "0xabcd")
  assert.equal(q.gas, null)
  assert.equal(parseZeroX({ ...firm, transaction: { ...firm.transaction, gas: "773673" } }, true).gas, 773673n)
})

test("a firm quote pointing anywhere else is refused", () => {
  const evil = "0x000000000000000000000000000000000000dEaD"
  assert.throws(() => parseZeroX({ ...firm, transaction: { ...firm.transaction, to: evil } }, true), /refused/)
  assert.throws(() => parseZeroX({ ...firm, issues: { allowance: { spender: evil } } }, true), /refused/)
})

test("a preview needs no transaction, but no route or zero out is an error", () => {
  assert.equal(parseZeroX({ buyAmount: "5", minBuyAmount: "4" }, false).buyAmount, 5n)
  assert.throws(() => parseZeroX({ liquidityAvailable: false }, false), /No swap route/)
  assert.throws(() => parseZeroX({ buyAmount: "0", minBuyAmount: "0" }, false), /empty/)
})

test("zeroX hits the same-origin proxy with the right params", async () => {
  let seen
  const fake = async (url) => {
    seen = url
    return { ok: true, status: 200, json: async () => firm }
  }
  await zeroX("quote", { sell: COINS.usdc.address, buy: COINS.pinto.address, amount: 5000000n, taker: "0x1", slipBps: 100 }, fake)
  assert.match(seen, /^\/api\/0x\/quote\?/)
  assert.match(seen, /sellAmount=5000000/)
  assert.match(seen, /slippageBps=100/)
  assert.match(seen, /taker=0x1/)
})

test("Max keeps gas back on ETH only", () => {
  assert.equal(maxSpend(COINS.eth, GAS_KEEP + 5n), 5n)
  assert.equal(maxSpend(COINS.eth, 1n), 0n)
  assert.equal(maxSpend(COINS.usdc, 7n), 7n)
  assert.equal(maxSpend(COINS.usdc, null), null)
})

test("received spends the real rise, and falls back to the floor on a stale read", () => {
  assert.equal(received(100n, 200n, 90n), 100n)
  assert.equal(received(100n, 100n, 90n), 90n)
  assert.equal(received(100n, 150n, 90n), 90n)
})
