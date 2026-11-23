import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

const indexHtml = readFileSync(new URL("./index.html", import.meta.url), "utf8")
const chirpHtml = readFileSync(new URL("./chirp.html", import.meta.url), "utf8")

test("index.html is the Surco coins front page linking to Chirp, Launch, Stake, Docs, and Pinto", () => {
  assert.match(indexHtml, /Coins backed by Pinto/)
  assert.match(indexHtml, /Coins that buy themselves back/)
  for (const id of ["coins-body", "coins-mobile", "coins-search", "coins-meta", "coins-more", "test-banner", "connect", "copyLink"]) {
    assert.match(indexHtml, new RegExp(`id="${id}"`), id)
  }
  for (const href of ["/chirp", "/launch", "/stake", "/creator", "/pinto", "/docs", "/press", "https://github.com/Surco-org/surco"]) {
    assert.match(indexHtml, new RegExp(`href="${href}"`), href)
  }
  assert.doesNotMatch(indexHtml, /<script>/) // strict CSP blocks inline scripts
  assert.match(indexHtml, /src="\/coins-page\.js"/)
})

test("chirp.html is Chirp's custom coin page with all shop, chart, and field hooks", () => {
  for (const id of [
    "connect", "price", "shelf", "side-buy", "side-sell", "amount", "max",
    "pay-token", "out", "get-token", "fee", "warn", "go", "slip", "slip-note",
    "status", "hold", "trade", "f-silo", "f-stalk", "f-grown", "f-yield",
    "f-burned", "f-pile", "f-sow", "f-plots", "do-claim", "do-sow", "do-harvest", "coin",
  ]) {
    assert.match(chirpHtml, new RegExp(`id="${id}"`), id)
  }
  assert.match(chirpHtml, /0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13/)
  assert.doesNotMatch(chirpHtml, /<script>/)
})

test("no id is used twice on index.html or chirp.html", () => {
  for (const [name, html] of [["index.html", indexHtml], ["chirp.html", chirpHtml]]) {
    const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
    assert.deepEqual(ids.filter((id, i) => ids.indexOf(id) !== i), [], name)
  }
})
