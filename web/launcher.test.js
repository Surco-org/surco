import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import { decodeAbiParameters, decodeFunctionData, parseAbiParameters } from "viem"
import { HOOK, UNIVERSAL_ROUTER_ABI, WETH } from "./launcher-config.js"
import { buildChirpEntry, formatVeCell, matchesChirpQuery } from "./coins-page.js"
import {
  ADDRESS_MSG_SENDER,
  ADDRESS_THIS,
  applySlippage,
  buildPoolKey,
  encodeBuyWithEth,
  encodeBuyWithWeth,
  encodeSellToEth,
  encodeSellToWeth,
  estimateFirstBuyCoins,
  feeSplitBps,
  monogramInfo,
  redeemPreview,
  sanitizeExternalUrl,
  sanitizeImageUri,
  tollBpsAt,
  veWeightAt,
} from "./launcher-core.js"

const HIGH_COIN = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
const LOW_COIN = "0x1111111111111111111111111111111111111111"

test("sanitizeImageUri accepts https and ipfs, rejects dangerous schemes", () => {
  assert.equal(sanitizeImageUri("https://surcofi.com/api/launcher/image/abc.png"), "https://surcofi.com/api/launcher/image/abc.png")
  assert.equal(sanitizeImageUri("ipfs://QmTestCid123/logo.png"), "https://dweb.link/ipfs/QmTestCid123/logo.png")
  assert.equal(sanitizeImageUri("ipfs://ipfs/bafy123"), "https://dweb.link/ipfs/bafy123")
  assert.equal(sanitizeImageUri("javascript:alert(1)"), "")
  assert.equal(sanitizeImageUri("data:image/svg+xml,<svg/>"), "")
  assert.equal(sanitizeImageUri("http://insecure.example/a.png"), "")
  assert.equal(sanitizeImageUri("ipfs://../../etc/passwd"), "")
  assert.equal(sanitizeImageUri("https://a.com/x\ny"), "")

  assert.equal(sanitizeExternalUrl("https://example.org"), "https://example.org/")
  assert.equal(sanitizeExternalUrl("surcofi.com"), "https://surcofi.com/")
  assert.equal(sanitizeExternalUrl("http://example.org"), "")
  assert.equal(sanitizeExternalUrl("javascript:alert(1)"), "")
})

test("monogramInfo is deterministic and safe", () => {
  const m = monogramInfo(HIGH_COIN, "demo!!")
  assert.equal(m.label, "DEM")
  assert.match(m.bg, /^hsl\(\d+ 42% 86%\)$/)
  assert.equal(monogramInfo(HIGH_COIN, "demo!!").bg, m.bg)
})

test("tollBpsAt matches FeeMath linear decay from 8000 to feeBps over 600s", () => {
  assert.equal(tollBpsAt(1000, 1000, 100), 8000)
  assert.equal(tollBpsAt(1300, 1000, 100), 4050)
  assert.equal(tollBpsAt(1599, 1000, 100), 114)
  assert.equal(tollBpsAt(1600, 1000, 100), 100)
  assert.equal(tollBpsAt(9999, 1000, 100), 100)
})

test("feeSplitBps and estimateFirstBuyCoins match contract constants", () => {
  assert.deepEqual(feeSplitBps(1000), { platformBps: 2000, creatorBps: 1000, pintoBps: 7000 })
  assert.deepEqual(feeSplitBps(2000), { platformBps: 2000, creatorBps: 2000, pintoBps: 6000 })
  assert.deepEqual(feeSplitBps(0), { platformBps: 2000, creatorBps: 0, pintoBps: 8000 })

  // 0.001 ETH first buy at 1% fee -> ~98,990 coins (within tick rounding)
  const est = estimateFirstBuyCoins(1_000_000_000_000_000n, 100)
  const whole = Number(est) / 1e18
  assert.ok(whole > 98_500 && whole < 99_500, `unexpected first buy estimate: ${whole}`)
})

test("redeemPreview mirrors RedeemVault 1% fee rounding up", () => {
  const r = redeemPreview(10_000_000n * 10n ** 18n, 1_000_000_000n * 10n ** 18n, 100_000_000n)
  assert.equal(r.gross, 1_000_000n) // 1% of 100 Pinto = 1 Pinto
  assert.equal(r.fee, 10_000n) // 1% fee
  assert.equal(r.out, 990_000n)
  assert.equal(applySlippage(1_000_000n, 100), 990_000n)
})

test("Universal Router v4 encodings produce valid commands and action sequences for both sort orders", () => {
  for (const addr of [HIGH_COIN, LOW_COIN]) {
    const { poolKey, coinIsToken0 } = buildPoolKey(addr, HOOK)
    assert.equal(coinIsToken0, addr === LOW_COIN)

    const buyEth = encodeBuyWithEth(poolKey, coinIsToken0, 10n ** 16n, 123n, 9999999999n)
    assert.equal(buyEth.commands, "0x0b10") // WRAP_ETH + V4_SWAP
    assert.equal(buyEth.value, 10n ** 16n)
    const decBuy = decodeFunctionData({ abi: UNIVERSAL_ROUTER_ABI, data: buyEth.data })
    assert.equal(decBuy.functionName, "execute")
    const [wrapTo, wrapAmt] = decodeAbiParameters(parseAbiParameters("address, uint256"), buyEth.inputs[0])
    assert.equal(wrapTo.toLowerCase(), ADDRESS_THIS)
    assert.equal(wrapAmt, 10n ** 16n)
    const [buyActions] = decodeAbiParameters(parseAbiParameters("bytes, bytes[]"), buyEth.inputs[1])
    assert.equal(buyActions, "0x060b0f") // SWAP_EXACT_IN_SINGLE + SETTLE(payerIsUser=false) + TAKE_ALL

    const buyWeth = encodeBuyWithWeth(poolKey, coinIsToken0, 10n ** 16n, 123n, 9999999999n)
    assert.equal(buyWeth.commands, "0x10")
    assert.equal(buyWeth.value, 0n)

    const sellRecipient = "0x9999999999999999999999999999999999999999"
    const sellEth = encodeSellToEth(poolKey, coinIsToken0, 10n ** 21n, 55n, 9999999999n, sellRecipient)
    assert.equal(sellEth.commands, "0x100c") // V4_SWAP + UNWRAP_WETH
    const [sellActions] = decodeAbiParameters(parseAbiParameters("bytes, bytes[]"), sellEth.inputs[0])
    assert.equal(sellActions, "0x060c0e") // SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE(ADDRESS_THIS)
    const [unwrapTo, unwrapMin] = decodeAbiParameters(parseAbiParameters("address, uint256"), sellEth.inputs[1])
    assert.equal(unwrapTo.toLowerCase(), sellRecipient.toLowerCase())
    assert.equal(unwrapMin, 55n)

    const sellWeth = encodeSellToWeth(poolKey, coinIsToken0, 10n ** 21n, 55n, 9999999999n)
    assert.equal(sellWeth.commands, "0x10")
    assert.equal(poolKey.currency0.toLowerCase() === WETH.toLowerCase() ? !coinIsToken0 : coinIsToken0, true)
  }
})

test("veWeightAt mirrors VeChirp linear decay and permanent max-lock math", () => {
  const amt = 365n * 10n ** 18n
  assert.equal(veWeightAt(amt, 365, false), amt)
  assert.equal(veWeightAt(amt, 100, false), 100n * 10n ** 18n)
  assert.equal(veWeightAt(amt, 2, false), 2n * 10n ** 18n)
  assert.equal(veWeightAt(amt, 0, false), 0n)
  assert.equal(veWeightAt(amt, 0, true), amt)
})

test("buildChirpEntry formats flagship Chirp row pointing to /chirp and filters cleanly", () => {
  const row = buildChirpEntry({
    pintoUsd: 0.02,
    chirpUsd: 0.00025,
    field: { supply: String(999_000_000n * 10n ** 18n), silo: String(500_000n * 10n ** 6n) },
    stats: { trades: 42, volumePinto: String(1_250_000n * 10n ** 6n) },
  })
  assert.equal(row.href, "/chirp")
  assert.equal(row.mode, "flagship")
  assert.equal(row.symbol, "CHIRP")
  assert.equal(row.siloPintoNum, 500_000)
  assert.equal(row.trades24h, 42)
  assert.ok(row.fdvUsd > 240_000 && row.fdvUsd < 260_000)
  assert.equal(matchesChirpQuery(""), true)
  assert.equal(matchesChirpQuery("chirp"), true)
  assert.equal(matchesChirpQuery("0x4d2d"), true)
  assert.equal(matchesChirpQuery("demo"), false)

  const snap = {
    active: true,
    silo: { totalLockedChirp: String(10_000n * 10n ** 18n), totalWeightToday: "54794520547945205479" },
    coinWeights: { "0x62fbb2379cb12b75c1cdaffbb69f61757e89288d": "54794520547945205479" },
  }
  const chuckVe = formatVeCell({ coin: "0x62FBB2379cb12B75c1CDAFFBb69f61757e89288D", mode: "burn" }, snap)
  assert.equal(chuckVe.main, "54.795 veChirp")
  assert.equal(chuckVe.sub, "100% gauge")
  const zeroVe = formatVeCell({ coin: "0x0000000000000000000000000000000000000001", mode: "burn" }, snap)
  assert.equal(zeroVe.main, "0 veChirp")
  assert.equal(zeroVe.sub, "0% gauge")
  const chirpVe = formatVeCell({ mode: "flagship" }, snap)
  assert.match(chirpVe.main, /locked/)
  assert.equal(chirpVe.sub, "54.795 total veChirp")
})

test("all 7 launcher, front & docs HTML pages obey strict CSP (no inline scripts) and have zero duplicate IDs", () => {
  const pages = [
    { file: "./index.html", mustHave: ["coins-body", "coins-search", "test-banner", "connect", "copyLink"] },
    { file: "./coins.html", mustHave: ["coins-body", "coins-search", "test-banner", "connect"] },
    { file: "./launch.html", mustHave: ["launch-form", "f-name", "f-symbol", "f-website", "f-twitter", "f-desc", "adv-drawer", "f-fee-pct", "f-creator-pct", "launch-fee-note", "launch-submit"] },
    { file: "./coin.html", mustHave: ["coin-chart", "coin-website", "coin-twitter", "coin-desc", "trade-form", "redeem-form", "seed-form", "toll-banner", "activity-body", "stake-this-coin", "v-ve"] },
    { file: "./creator.html", mustHave: ["creator-lookup", "creator-addr", "creator-body", "c-paid", "c-claimable"] },
    { file: "./stake.html", mustHave: ["lock-form", "lk-amount", "lk-coin", "lk-perm", "lk-days", "lk-weight-out", "lk-submit", "cs-seed-form", "locks-body"] },
    { file: "./docs.html", mustHave: ["overview", "chirp", "pinto", "launcher", "modes", "vechirp", "upkeep", "contracts", "risks", "copyLink"] },
  ]
  for (const p of pages) {
    const html = readFileSync(new URL(p.file, import.meta.url), "utf8")
    assert.doesNotMatch(html, /<script(?:\s+type="[^"]*")?>/, `${p.file} must not contain inline <script>`)
    assert.match(html, /src="\/theme\.js"/, `${p.file} must load /theme.js`)
    const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])
    const dupes = ids.filter((id, i) => ids.indexOf(id) !== i)
    assert.deepEqual(dupes, [], `${p.file} has duplicate ids: ${dupes.join(", ")}`)
    for (const id of p.mustHave) {
      assert.match(html, new RegExp(`id="${id}"`), `${p.file} missing #${id}`)
    }
  }
  const docsHtml = readFileSync(new URL("./docs.html", import.meta.url), "utf8")
  const shownAddrs = new Set([...docsHtml.matchAll(/>(0x[0-9a-fA-F]{40})<\/a>/g)].map((m) => m[1]))
  assert.ok(shownAddrs.size >= 7, "docs.html should list live verified contract addresses")
  for (const a of shownAddrs) {
    assert.match(docsHtml, new RegExp(`href="https://basescan.org/address/${a}#code"[^>]*>Verified source<`), `docs.html missing Verified source for ${a}`)
  }
})
