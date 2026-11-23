import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import { label, TEAM } from "./labels.js"
import { activityRow } from "./activity.js"
import { holderRow } from "./holders.js"

const html = readFileSync(new URL("./chirp.html", import.meta.url), "utf8")

test("the app page carries every hook the shared modules need", () => {
  for (const id of [
    // shop.js
    "connect", "price", "shelf", "side-buy", "side-sell", "amount", "max", "pay-token", "out", "get-token", "fee",
    "warn", "go", "slip", "slip-note", "status", "hold", "trade", "coin", "coin-label", "route", "bal", "nav-bal",
    // market.js
    "usd", "mkt-price", "hero-usd", "hero-cap",
    // chart.js
    "chart", "chart-price", "chart-change", "chart-note",
    // field.js
    "f-silo", "f-stalk", "f-grown", "f-yield", "f-burned", "f-pile", "f-sow", "f-plots", "f-ripe", "do-claim", "do-sow",
    "do-harvest", "field-status",
    // page.js
    "themeToggle", "nav", "burger", "navLinks",
    // this page
    "activity", "activity-more", "holders", "holder-count", "s-holders", "s-trades", "s-wallets", "s-volume",
  ]) {
    assert.match(html, new RegExp(`id="${id}"`), id)
  }
})

test("no duplicate ids, no inline scripts, links home", () => {
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
  assert.deepEqual(ids.filter((id, i) => ids.indexOf(id) !== i), [])
  assert.doesNotMatch(html, /<script>/)
  assert.match(html, /href="\/"/)
  for (const s of ["page.js", "shop.js", "market.js", "field.js", "activity.js", "holders.js", "chart.js"]) {
    assert.match(html, new RegExp(`src="/${s}"`))
  }
})

test("the team wallet is labelled, in any case", () => {
  assert.deepEqual(label(TEAM.toUpperCase().replace("0X", "0x")), { name: "Team", tag: "TEAM" })
  assert.deepEqual(label("0x10b919A89a5ABfecEBd805836DA174F02B023756"), { name: "Book (unsold shelf)" })
  assert.equal(label("0x00000000000000000000000000000000000000ab"), null)
})

test("activity rows", () => {
  const base = { block: 1, log: 0, tx: "0xabc", t: 1000, extra: null }
  const buy = activityRow({ ...base, kind: "buy", who: TEAM, pinto: "1000000000", chirp: "98990199970202949907959" }, 1090)
  assert.equal(buy.kind, "Buy")
  assert.equal(buy.time, "1m ago")
  assert.equal(buy.who, "Team")
  assert.equal(buy.tag, "TEAM")
  assert.equal(buy.pinto, "1,000")
  assert.equal(buy.chirp, "98,990.2")
  assert.equal(buy.tx, "https://basescan.org/tx/0xabc")
  const bb = activityRow({ ...base, kind: "buyback", who: null, pinto: "5", chirp: "7" }, 1005)
  assert.equal(bb.kind, "Buyback")
  assert.equal(bb.who, "—")
  assert.equal(bb.whoHref, null)
  assert.equal(bb.time, "5s ago")
  const sell = activityRow({ ...base, kind: "sell", who: "0x00000000000000000000000000000000000000ab", pinto: "1", chirp: "1" }, 1000 + 3 * 86400)
  assert.equal(sell.who, "0x0000…00ab")
  assert.equal(sell.whoHref, "https://basescan.org/address/0x00000000000000000000000000000000000000ab")
  assert.equal(sell.time, "3d ago")
})

test("holder rows", () => {
  const h = holderRow({ addr: TEAM, bal: "10000000000000000000000000" }, 10n ** 27n, 2)
  assert.equal(h.rank, 2)
  assert.equal(h.pct, "1.00%")
  assert.equal(h.chirp, "10,000,000")
  assert.equal(h.who, "Team")
  assert.equal(h.tag, "TEAM")
  assert.equal(h.href, `https://basescan.org/address/${TEAM}`)
})

test("a wallet whose event API throws cannot stop the page", () => {
  const shop = readFileSync(new URL("./shop.js", import.meta.url), "utf8")
  assert.match(shop, /try \{\s*subscribeWallet\(\)\s*\} catch/)
  // every wallet-event subscription lives inside the guarded function
  const body = shop.slice(shop.indexOf("function subscribeWallet()"))
  assert.equal((shop.match(/ethereum\.on\?\./g) || []).length, (body.match(/ethereum\.on\?\./g) || []).length)
})

for (const file of ["chirp.html"]) {
  test(`${file}: the price chart card — ranges, units, chart.js loads last, no old SVG`, () => {
    const page = readFileSync(new URL(`./${file}`, import.meta.url), "utf8")
    for (const id of ["chart", "chart-price", "chart-change", "chart-note", "mkt-price", "usd"]) assert.match(page, new RegExp(`id="${id}"`), id)
    assert.doesNotMatch(page, /id="curve/)
    const ranges = [...page.matchAll(/<button[^>]*class="range"[^>]*data-range="([^"]+)"[^>]*aria-pressed="(true|false)"/g)]
    assert.deepEqual(ranges.map((m) => m[1]), ["1h", "24h", "7d", "all"])
    assert.deepEqual(ranges.filter((m) => m[2] === "true").map((m) => m[1]), ["24h"])
    const units = [...page.matchAll(/<button[^>]*class="unit"[^>]*data-unit="([^"]+)"[^>]*aria-pressed="(true|false)"/g)]
    assert.deepEqual(units.map((m) => [m[1], m[2]]), [["usd", "true"], ["pinto", "false"]])
    const scripts = [...page.matchAll(/<script type="module" src="([^"]+)"/g)].map((m) => m[1])
    assert.equal(scripts.at(-1), "/chart.js")
    const ids = [...page.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
    assert.deepEqual(ids.filter((id, i) => ids.indexOf(id) !== i), [])
  })
}

test("press.html: no duplicate ids, no inline scripts, logo files, contracts, linked from both pages", () => {
  const press = readFileSync(new URL("./press.html", import.meta.url), "utf8")
  const ids = [...press.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
  assert.deepEqual(ids.filter((id, i) => ids.indexOf(id) !== i), [])
  assert.doesNotMatch(press, /<script>/)
  for (const f of ["chirp-icon-512.png", "chirp-logo.jpg", "og.jpg"]) assert.match(press, new RegExp(`href="/${f}" download`))
  for (const a of ["0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13", "0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8"]) assert.match(press, new RegExp(a))
  for (const f of ["index.html", "chirp.html"]) assert.match(readFileSync(new URL(`./${f}`, import.meta.url), "utf8"), /href="\/press"/)
})

test("every page has the footer Copy link button for the home URL", () => {
  for (const f of ["index.html", "chirp.html", "press.html"]) {
    assert.match(readFileSync(new URL(`./${f}`, import.meta.url), "utf8"), /id="copyLink" type="button" data-copy="https:\/\/surcofi.com\/"/, f)
  }
})

test("pinto.html: no duplicate ids, no inline scripts, loads page.js + pinto.js, cites Pinto's docs, editor's note, linked from every page", () => {
  const page = readFileSync(new URL("./pinto.html", import.meta.url), "utf8")
  const ids = [...page.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
  assert.deepEqual(ids.filter((id, i) => ids.indexOf(id) !== i), [])
  assert.doesNotMatch(page, /<script>/)
  assert.match(page, /src="\/page.js"/)
  assert.match(page, /src="\/pinto.js"/)
  assert.match(page, /href="https:\/\/docs.pinto.money\/why-pinto\/why-pinto-overview"/)
  assert.match(page, /id="editors-note"/)
  assert.match(page, /data-live="price"/)
  for (const f of ["index.html", "chirp.html", "press.html"]) assert.match(readFileSync(new URL(`./${f}`, import.meta.url), "utf8"), /href="\/pinto"/, f)
})

test("pinto.html copy stays inside Pinto's own disclosures", () => {
  const page = readFileSync(new URL("./pinto.html", import.meta.url), "utf8")
  assert.doesNotMatch(page, /no one can freeze your Pinto/)            // Disclosure 7: the multisig can change Pinto
  assert.doesNotMatch(page, /moves around \$1 rather than sitting on it/) // Disclosure 5: no price guarantee
  assert.match(page, /href="https:\/\/docs.pinto.money\/appendix\/disclosures"/)
  assert.match(page, /may never be repaid/)                             // Disclosure 6: Pods have no maturity
  assert.doesNotMatch(page, /no one is rewarded for it/)                // every sow refers 0x0dB1…08bf
  assert.match(page, /0x0dB14dc82CBB0ce820F65c9796E0bC9E19eF08bf/)
})

test("every contract address shown has a Verified source link to its Basescan code tab", () => {
  for (const f of ["index.html", "chirp.html", "press.html"]) {
    const page = readFileSync(new URL(`./${f}`, import.meta.url), "utf8")
    const shown = new Set([...page.matchAll(/>(0x[0-9a-fA-F]{40})<\/a>/g)].map((m) => m[1]))
    for (const a of ["0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13", "0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8", "0x10b919A89a5ABfecEBd805836DA174F02B023756"]) {
      if (shown.has(a)) assert.match(page, new RegExp(`href="https://basescan.org/address/${a}#code"[^>]*>Verified source<`), `${f} ${a}`)
    }
  }
})
