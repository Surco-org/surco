import { AreaSeries, createChart, LineType } from "lightweight-charts"
import { erc20Abi, formatUnits, getAddress, isAddress, parseUnits } from "viem"
import {
  BASESCAN,
  FACTORY,
  IS_TEST_FACTORY,
  PINTO,
  QUOTER_ABI,
  SUPPLY_WEI,
  UNIVERSAL_ROUTER,
  UNIVERSAL_ROUTER_ABI,
  V4_QUOTER,
  VAULT_ABI,
  WETH,
} from "./launcher-config.js"
import {
  applySlippage,
  buildPoolKey,
  createAvatarEl,
  encodeBuyWithEth,
  encodeBuyWithWeth,
  encodeSellToEth,
  encodeSellToWeth,
  feeSplitBps,
  fmtPinto,
  fmtTokenAmount,
  fmtUsd,
  fmtWeiEth,
  fmtWeth,
  redeemPreview,
  relTime,
  sanitizeExternalUrl,
  sanitizeImageUri,
  shortAddr,
  tollBpsAt,
} from "./launcher-core.js"
import {
  connectWallet,
  ensureErc20Approval,
  ensurePermit2Approval,
  friendlyError,
  getWallet,
  initWalletButton,
  onWallet,
  publicClient,
  sendSimulatedWrite,
} from "./launcher-wallet.js"

initWalletButton("#connect")

const banner = document.querySelector("#test-banner")
const factoryLink = document.querySelector("#test-factory-link")
if (IS_TEST_FACTORY && banner) {
  banner.hidden = false
  if (factoryLink) {
    factoryLink.href = `${BASESCAN}/address/${FACTORY}`
    factoryLink.textContent = `Factory ${shortAddr(FACTORY)}`
  }
}

const $ = (s) => document.querySelector(s)
const params = new URLSearchParams(window.location.search)
const coinParam = (params.get("a") || "").trim()

const state = {
  coinAddr: isAddress(coinParam) ? getAddress(coinParam) : "",
  data: null,
  range: "24h",
  unit: "usd",
  side: "buy",
  asset: "eth",
  quotedOut: 0n,
  quoteSeq: 0,
  balances: { eth: 0n, weth: 0n, coin: 0n, pinto: 0n, vaultUnbookedPinto: 0n },
  busy: false,
}

let chart = null
let series = null

function showError(msg) {
  $("#coin-shell").hidden = true
  const el = $("#coin-error")
  el.hidden = false
  el.textContent = msg
}

function setupChart() {
  const box = $("#coin-chart")
  if (!box || chart) return
  chart = createChart(box, {
    autoSize: true,
    layout: { background: { color: "transparent" }, fontFamily: getComputedStyle(document.body).fontFamily },
    rightPriceScale: { borderVisible: false },
    timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false },
    handleScale: { mouseWheel: false },
  })
  series = chart.addSeries(AreaSeries, { lineWidth: 2, lineType: LineType.WithSteps, priceLineVisible: false })
  paintChartTheme()
  new MutationObserver(paintChartTheme).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
}

function paintChartTheme() {
  if (!chart || !series) return
  const css = getComputedStyle(document.documentElement)
  const v = (k) => css.getPropertyValue(k).trim()
  const line = v("--accent-2") || "#3f9d8c"
  chart.applyOptions({
    layout: { textColor: v("--faint") || "#7c9479" },
    grid: { vertLines: { visible: false }, horzLines: { color: "rgba(128,128,128,0.12)" } },
  })
  series.applyOptions({ lineColor: line, topColor: "rgba(63,157,140,0.24)", bottomColor: "rgba(63,157,140,0.02)" })
}

function renderChart() {
  if (!series || !state.data) return
  const { wethUsd, chart: ch } = state.data
  const mult = state.unit === "usd" && wethUsd > 0 ? wethUsd : 1
  const pts = []
  let lastT = -1
  for (const [t, pw] of ch.points || []) {
    const val = pw * mult
    if (!Number.isFinite(val) || val <= 0) continue
    if (t === lastT && pts.length) pts[pts.length - 1] = { time: t, value: val }
    else if (t > lastT) {
      pts.push({ time: t, value: val })
      lastT = t
    }
  }
  series.applyOptions({
    priceFormat: {
      type: "custom",
      minMove: 1e-12,
      formatter: (val) => (state.unit === "usd" && wethUsd > 0 ? fmtUsd(val) : fmtWeth(val)),
    },
  })
  series.setData(pts)
  if (pts.length) chart.timeScale().fitContent()
  $("#coin-chart-note").textContent = pts.length
    ? `Showing ${pts.length} price point${pts.length === 1 ? "" : "s"} (${state.unit.toUpperCase()}).`
    : "No swaps indexed in this range yet."
}

function updateTollBanner() {
  const c = state.data?.coin
  const el = $("#toll-banner")
  if (!c || !el) return
  const nowSec = Math.floor(Date.now() / 1000)
  const bps = tollBpsAt(nowSec, c.launchedAt, c.feeBps)
  if (c.tollEndsAt > nowSec && bps > c.feeBps) {
    const rem = c.tollEndsAt - nowSec
    const mins = Math.floor(rem / 60)
    const secs = String(rem % 60).padStart(2, "0")
    el.hidden = false
    el.textContent = `Anti-sniper toll active: swaps currently pay ${(bps / 100).toFixed(2)}% (decays to ${(c.feeBps / 100).toFixed(2)}% in ${mins}:${secs}).`
    $("#t-fee").textContent = `${(bps / 100).toFixed(2)}% (sniper toll)`
    const warn = $("#t-warn")
    warn.hidden = false
    warn.textContent = `High launch fee active (${(bps / 100).toFixed(2)}%). Wait ${mins}:${secs} for the normal ${(c.feeBps / 100).toFixed(2)}% fee.`
  } else {
    el.hidden = true
    $("#t-fee").textContent = `${(c.feeBps / 100).toFixed(2)}%`
    $("#t-warn").hidden = true
  }
}

function renderActivity(items, sym) {
  const tbody = $("#activity-body")
  tbody.textContent = ""
  if (!items?.length) {
    const tr = document.createElement("tr")
    const td = document.createElement("td")
    td.colSpan = 4
    td.className = "l-empty"
    td.textContent = "No swaps or vault events yet."
    tr.appendChild(td)
    tbody.appendChild(tr)
    return
  }
  const labels = {
    buy: "Buy",
    sell: "Sell",
    convert: "Convert → Silo",
    seed: "Seed Silo",
    buyback: "Buyback & Burn",
    redeem: "Redeem",
    payout_changed: "Payout changed",
  }
  for (const it of items) {
    const tr = document.createElement("tr")
    const tdKind = document.createElement("td")
    tdKind.textContent = labels[it.kind] || it.kind

    const tdAmt = document.createElement("td")
    tdAmt.className = "l-num"
    if (it.kind === "buy" || it.kind === "sell") {
      tdAmt.textContent = `${fmtWeiEth(it.wethWei)} ↔ ${fmtTokenAmount(it.coinWei)} ${sym}`
    } else if (it.kind === "convert") {
      tdAmt.textContent = `${fmtWeiEth(it.amountA)} → ${fmtPinto(Number(BigInt(it.amountB || "0")) / 1e6)}`
    } else if (it.kind === "seed") {
      tdAmt.textContent = fmtPinto(Number(BigInt(it.amountA || "0")) / 1e6)
    } else if (it.kind === "buyback") {
      tdAmt.textContent = `${fmtTokenAmount(it.amountB)} ${sym} burned`
    } else if (it.kind === "redeem") {
      tdAmt.textContent = `${fmtTokenAmount(it.amountA)} ${sym} → ${fmtPinto(Number(BigInt(it.amountB || "0")) / 1e6)}`
    } else {
      tdAmt.textContent = it.actor ? shortAddr(it.actor) : "—"
    }

    const tdTime = document.createElement("td")
    tdTime.className = "l-num"
    tdTime.textContent = relTime(it.t)

    const tdTx = document.createElement("td")
    tdTx.className = "l-num"
    const a = document.createElement("a")
    a.href = `${BASESCAN}/tx/${it.tx}`
    a.target = "_blank"
    a.rel = "noopener"
    a.textContent = `${it.tx.slice(0, 8)}…`
    a.style.textDecoration = "underline"
    tdTx.appendChild(a)

    tr.append(tdKind, tdAmt, tdTime, tdTx)
    tbody.appendChild(tr)
  }
}

function renderCoin() {
  const d = state.data
  if (!d) return
  const c = d.coin
  $("#coin-error").hidden = true
  $("#coin-shell").hidden = false
  $("#hidden-banner").hidden = !c.hidden

  document.title = `${c.symbol || c.name || "Coin"} — Surco`
  const slot = $("#coin-avatar-slot")
  slot.textContent = ""
  slot.appendChild(createAvatarEl(c.imageUri, c.coin, c.symbol, "lg"))

  $("#coin-title").textContent = c.name || "Unnamed"
  $("#coin-symbol").textContent = c.symbol || ""
  const badge = $("#coin-mode-badge")
  badge.textContent = c.mode === "redeem" ? "Redeem" : "Burn"
  badge.className = `l-badge ${c.mode === "redeem" ? "redeem" : ""}`.trim()

  $("#coin-scan").href = `${BASESCAN}/token/${c.coin}`
  $("#vault-scan").href = `${BASESCAN}/address/${c.vault}`
  $("#creator-link").href = `/creator?a=${encodeURIComponent(c.creatorPayout)}`
  $("#creator-link").textContent = `Creator ${shortAddr(c.creatorPayout)}`
  const stakeLink = $("#stake-this-coin")
  if (stakeLink) stakeLink.href = `/stake?coin=${encodeURIComponent(c.coin)}`

  const safeWeb = sanitizeExternalUrl(c.websiteUrl)
  const webEl = $("#coin-website")
  if (webEl) {
    webEl.hidden = !safeWeb
    if (safeWeb) webEl.href = safeWeb
  }
  const safeTw = sanitizeExternalUrl(c.twitterUrl)
  const twEl = $("#coin-twitter")
  if (twEl) {
    twEl.hidden = !safeTw
    if (safeTw) twEl.href = safeTw
  }
  const safeMeta = sanitizeImageUri(c.metadataUri)
  const metaEl = $("#coin-meta-link")
  if (metaEl) {
    metaEl.hidden = !safeMeta
    if (safeMeta) metaEl.href = safeMeta
  }
  const descEl = $("#coin-desc")
  if (descEl) {
    descEl.hidden = !c.description
    descEl.textContent = c.description || ""
  }

  $("#coin-price-main").textContent = c.priceUsd > 0 ? fmtUsd(c.priceUsd) : fmtWeth(c.priceWeth)
  $("#coin-fdv-sub").textContent = c.fdvUsd > 0 ? `FDV ${fmtUsd(c.fdvUsd)}` : `FDV ${fmtWeth(c.fdvWeth)}`

  $("#v-silo").textContent = `${fmtPinto(c.siloPintoNum)}${c.siloPintoUsd > 0 ? ` (${fmtUsd(c.siloPintoUsd)})` : ""}`
  const supplyBig = BigInt(c.totalSupply || String(SUPPLY_WEI))
  const burnedBig = SUPPLY_WEI > supplyBig ? SUPPLY_WEI - supplyBig : 0n
  if (c.mode === "redeem") {
    $("#v-extra-k").textContent = "Redeem / 1M coins"
    const p1m = redeemPreview(1_000_000n * 10n ** 18n, supplyBig, BigInt(c.siloPinto || "0"))
    $("#v-extra-v").textContent = fmtPinto(Number(p1m.out) / 1e6)
    $("#v-mode-note").textContent = "Redeem mode: any holder can burn coins for their share of Silo Pinto (minus 1% fee)."
    $("#redeem-card").hidden = false
  } else {
    $("#v-extra-k").textContent = "Burned so far"
    $("#v-extra-v").textContent = `${fmtTokenAmount(String(burnedBig))} ${c.symbol}`
    $("#v-mode-note").textContent = "Burn mode: Silo Pinto principal is locked forever; Silo yield buys and burns this coin when Pinto is above $1."
    $("#redeem-card").hidden = true
  }

  const totalPendingWeth = BigInt(c.pendingWeth || "0") + BigInt(c.unsplitWeth || "0")
  $("#v-pending").textContent = fmtWeiEth(String(totalPendingWeth))
  $("#v-vol").textContent = c.vol24hUsd > 0 ? fmtUsd(c.vol24hUsd) : fmtWeth(c.vol24hWeth)
  const split = feeSplitBps(c.creatorBps)
  $("#v-fee").textContent = `${(c.feeBps / 100).toFixed(2)}% (${split.pintoBps / 100}% Silo)`
  $("#v-supply").textContent = fmtTokenAmount(c.totalSupply)

  const veEl = $("#v-ve")
  const veNoteEl = $("#v-ve-note")
  if (state.stakeSnap?.active) {
    const rawW = state.stakeSnap.coinWeights?.[String(c.coin || "").toLowerCase()] || "0"
    const w = BigInt(rawW)
    const totalW = BigInt(state.stakeSnap.silo?.totalWeightToday || "0")
    if (w > 0n) {
      const pct = totalW > 0n ? (Number((w * 10000n) / totalW) / 100) : 0
      const pctStr = pct >= 99.95 ? "100%" : `${pct.toFixed(1)}%`
      const wStr = fmtTokenAmount(String(w))
      if (veEl) veEl.textContent = `${wStr} veChirp (${pctStr})`
      if (veNoteEl) veNoteEl.textContent = `${wStr} veChirp (${pctStr} of active gauge) directs Collective Silo yield to ${c.symbol}.`
    } else {
      if (veEl) veEl.textContent = "0 veChirp"
      if (veNoteEl) veNoteEl.textContent = `No veChirp staked on ${c.symbol} yet — lock Chirp to direct Collective Silo yield here.`
    }
  }

  setupChart()
  renderChart()
  renderActivity(d.activity, c.symbol || "")
  updateTollBanner()
  updateTradeLabels()
}

async function loadCoin() {
  if (!state.coinAddr) {
    showError("Missing or invalid coin address. Pick a coin from /coins.")
    return
  }
  try {
    const [res, stakeRes] = await Promise.all([
      fetch(`/api/launcher/coin?a=${encodeURIComponent(state.coinAddr)}&range=${state.range}`),
      fetch("/api/launcher/stake").catch(() => null),
    ])
    const data = await res.json().catch(() => ({}))
    if (!res.ok) {
      showError(data.error || "Coin not found on this factory.")
      return
    }
    if (stakeRes && stakeRes.ok) {
      state.stakeSnap = await stakeRes.json().catch(() => state.stakeSnap)
    }
    state.data = data
    renderCoin()
    refreshBalances()
    refreshQuote()
  } catch {
    showError("Could not load coin data right now.")
  }
}

async function refreshBalances() {
  const c = state.data?.coin
  if (!c) return
  try {
    const vaultPinto = await publicClient.readContract({
      address: PINTO,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [getAddress(c.vault)],
    })
    state.balances.vaultUnbookedPinto = vaultPinto
    const box = $("#seed-pending-box")
    if (vaultPinto > 0n) {
      box.hidden = false
      $("#seed-pending-text").textContent = `${fmtPinto(Number(vaultPinto) / 1e6)} waiting in vault to be booked.`
    } else {
      box.hidden = true
    }
  } catch {}

  const { account } = getWallet()
  if (!account) {
    $("#t-bal").textContent = "Balance: —"
    return
  }
  try {
    const [eth, weth, coinBal, pinto] = await Promise.all([
      publicClient.getBalance({ address: account }),
      publicClient.readContract({ address: WETH, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
      publicClient.readContract({ address: getAddress(c.coin), abi: erc20Abi, functionName: "balanceOf", args: [account] }),
      publicClient.readContract({ address: PINTO, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
    ])
    state.balances = { ...state.balances, eth, weth, coin: coinBal, pinto }
    updateTradeLabels()
  } catch {}
}

function updateTradeLabels() {
  const c = state.data?.coin
  const sym = c?.symbol || "coin"
  const assetLabel = state.asset === "eth" ? "ETH" : "WETH"
  const isBuy = state.side === "buy"
  $("#t-pay-label").textContent = isBuy ? `You pay (${assetLabel})` : `You sell (${sym})`
  $("#t-submit").textContent = isBuy ? `Buy ${sym}` : `Sell ${sym} for ${assetLabel}`
  if (!getWallet().account) {
    $("#t-bal").textContent = "Balance: —"
  } else if (isBuy) {
    const b = state.asset === "eth" ? state.balances.eth : state.balances.weth
    $("#t-bal").textContent = `Balance: ${fmtWeiEth(String(b)).replace(" ETH", "")} ${assetLabel}`
  } else {
    $("#t-bal").textContent = `Balance: ${fmtTokenAmount(String(state.balances.coin))} ${sym}`
  }
}

async function refreshQuote() {
  const c = state.data?.coin
  const outEl = $("#t-out")
  if (!c) return
  const raw = $("#t-amount").value.trim()
  if (!raw) {
    state.quotedOut = 0n
    outEl.textContent = "—"
    return
  }
  let amountIn
  try {
    amountIn = parseUnits(raw, 18)
    if (amountIn <= 0n || amountIn > (1n << 128n) - 1n) throw new Error()
  } catch {
    state.quotedOut = 0n
    outEl.textContent = "—"
    return
  }

  const seq = ++state.quoteSeq
  outEl.textContent = "Quoting…"
  try {
    const { poolKey, coinIsToken0 } = buildPoolKey(c.coin, c.poolKey.hooks)
    const zeroForOne = state.side === "buy" ? !coinIsToken0 : coinIsToken0
    const { result } = await publicClient.simulateContract({
      address: V4_QUOTER,
      abi: QUOTER_ABI,
      functionName: "quoteExactInputSingle",
      args: [{ poolKey, zeroForOne, exactAmount: amountIn, hookData: "0x" }],
    })
    if (seq !== state.quoteSeq) return
    const amountOut = result[0]
    state.quotedOut = amountOut
    outEl.textContent =
      state.side === "buy"
        ? `${fmtTokenAmount(String(amountOut))} ${c.symbol}`
        : `${fmtWeiEth(String(amountOut)).replace(" ETH", "")} ${state.asset.toUpperCase()}`
  } catch {
    if (seq !== state.quoteSeq) return
    state.quotedOut = 0n
    outEl.textContent = "No quote"
  }
}

// Trade controls
$("#t-buy")?.addEventListener("click", () => {
  state.side = "buy"
  $("#t-buy").setAttribute("aria-pressed", "true")
  $("#t-sell").setAttribute("aria-pressed", "false")
  updateTradeLabels()
  refreshQuote()
})
$("#t-sell")?.addEventListener("click", () => {
  state.side = "sell"
  $("#t-buy").setAttribute("aria-pressed", "false")
  $("#t-sell").setAttribute("aria-pressed", "true")
  updateTradeLabels()
  refreshQuote()
})
$("#t-asset")?.addEventListener("change", (e) => {
  state.asset = e.target.value
  updateTradeLabels()
  refreshQuote()
})
$("#t-max")?.addEventListener("click", () => {
  let bal = 0n
  if (state.side === "buy") {
    if (state.asset === "eth") {
      // Leave a small ETH gas reserve
      bal = state.balances.eth > 2_000_000_000_000_000n ? state.balances.eth - 2_000_000_000_000_000n : 0n
    } else bal = state.balances.weth
  } else {
    bal = state.balances.coin
  }
  $("#t-amount").value = bal > 0n ? formatUnits(bal, 18) : ""
  refreshQuote()
})

let qTimer = null
$("#t-amount")?.addEventListener("input", () => {
  clearTimeout(qTimer)
  qTimer = setTimeout(refreshQuote, 180)
})

$("#trade-form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  if (state.busy || !state.data) return
  const statusEl = $("#t-status")
  const setStatus = (m, cls = "") => {
    statusEl.textContent = m
    statusEl.className = `l-status ${cls}`.trim()
  }
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()

    const c = state.data.coin
    const amountIn = parseUnits($("#t-amount").value.trim() || "0", 18)
    if (amountIn <= 0n) {
      setStatus("Enter an amount first.", "err")
      return
    }
    await refreshQuote()
    if (state.quotedOut <= 0n) {
      setStatus("Could not quote that swap size.", "err")
      return
    }

    const slipBps = Number($("#t-slip").value || 100)
    const minOut = applySlippage(state.quotedOut, slipBps)
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600)
    const { poolKey, coinIsToken0 } = buildPoolKey(c.coin, c.poolKey.hooks)

    state.busy = true
    $("#t-submit").disabled = true

    let call
    if (state.side === "buy" && state.asset === "eth") {
      call = encodeBuyWithEth(poolKey, coinIsToken0, amountIn, minOut, deadline)
    } else if (state.side === "buy") {
      await ensurePermit2Approval(WETH, UNIVERSAL_ROUTER, amountIn, setStatus)
      call = encodeBuyWithWeth(poolKey, coinIsToken0, amountIn, minOut, deadline)
    } else if (state.asset === "eth") {
      await ensurePermit2Approval(getAddress(c.coin), UNIVERSAL_ROUTER, amountIn, setStatus)
      call = encodeSellToEth(poolKey, coinIsToken0, amountIn, minOut, deadline, account)
    } else {
      await ensurePermit2Approval(getAddress(c.coin), UNIVERSAL_ROUTER, amountIn, setStatus)
      call = encodeSellToWeth(poolKey, coinIsToken0, amountIn, minOut, deadline)
    }

    await sendSimulatedWrite(
      {
        address: UNIVERSAL_ROUTER,
        abi: UNIVERSAL_ROUTER_ABI,
        functionName: "execute",
        args: [call.commands, call.inputs, call.deadline],
        value: call.value,
      },
      setStatus,
    )
    setStatus("Swap confirmed on Base!", "ok")
    $("#t-amount").value = ""
    await loadCoin()
  } catch (err) {
    setStatus(friendlyError(err), "err")
  } finally {
    state.busy = false
    $("#t-submit").disabled = false
  }
})

// Redeem form (Redeem mode)
$("#r-amount")?.addEventListener("input", () => {
  const c = state.data?.coin
  if (!c) return
  try {
    const amt = parseUnits($("#r-amount").value.trim() || "0", 18)
    const { out } = redeemPreview(amt, BigInt(c.totalSupply || String(SUPPLY_WEI)), BigInt(c.siloPinto || "0"))
    $("#r-out").textContent = out > 0n ? fmtPinto(Number(out) / 1e6) : "—"
  } catch {
    $("#r-out").textContent = "—"
  }
})

$("#redeem-form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  if (state.busy || !state.data) return
  const statusEl = $("#r-status")
  const setStatus = (m, cls = "") => {
    statusEl.textContent = m
    statusEl.className = `l-status ${cls}`.trim()
  }
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    const c = state.data.coin
    const amt = parseUnits($("#r-amount").value.trim() || "0", 18)
    if (amt <= 0n) {
      setStatus("Enter a coin amount to redeem.", "err")
      return
    }
    const { out } = redeemPreview(amt, BigInt(c.totalSupply || String(SUPPLY_WEI)), BigInt(c.siloPinto || "0"))
    const minPinto = applySlippage(out, 100)

    state.busy = true
    $("#r-submit").disabled = true
    await ensureErc20Approval(getAddress(c.coin), getAddress(c.vault), amt, setStatus)
    await sendSimulatedWrite(
      {
        address: getAddress(c.vault),
        abi: VAULT_ABI,
        functionName: "redeem",
        args: [amt, minPinto, account],
      },
      setStatus,
    )
    setStatus("Redeemed for Pinto!", "ok")
    $("#r-amount").value = ""
    $("#r-out").textContent = "—"
    await loadCoin()
  } catch (err) {
    setStatus(friendlyError(err, { ZeroOut: "Amount is too small to redeem.", Slippage: "Vault state moved; retry." }), "err")
  } finally {
    state.busy = false
    $("#r-submit").disabled = false
  }
})

// Seed form (2-step: transfer Pinto to vault, then seed())
async function runSeedOnly(setStatus) {
  const c = state.data.coin
  await sendSimulatedWrite(
    {
      address: getAddress(c.vault),
      abi: VAULT_ABI,
      functionName: "seed",
    },
    setStatus,
  )
}

$("#seed-book-only")?.addEventListener("click", async () => {
  if (state.busy || !state.data) return
  const statusEl = $("#s-status")
  const setStatus = (m, cls = "") => {
    statusEl.textContent = m
    statusEl.className = `l-status ${cls}`.trim()
  }
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    state.busy = true
    await runSeedOnly(setStatus)
    setStatus("Pinto booked into the Silo!", "ok")
    await loadCoin()
  } catch (err) {
    setStatus(friendlyError(err, { NothingPending: "No unbooked Pinto in the vault." }), "err")
  } finally {
    state.busy = false
  }
})

$("#seed-form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  if (state.busy || !state.data) return
  const statusEl = $("#s-status")
  const setStatus = (m, cls = "") => {
    statusEl.textContent = m
    statusEl.className = `l-status ${cls}`.trim()
  }
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    const c = state.data.coin
    const amt = parseUnits($("#s-amount").value.trim() || "0", 6)
    if (amt <= 0n) {
      setStatus("Enter a Pinto amount to seed.", "err")
      return
    }
    state.busy = true
    $("#s-submit").disabled = true
    await sendSimulatedWrite(
      {
        address: PINTO,
        abi: erc20Abi,
        functionName: "transfer",
        args: [getAddress(c.vault), amt],
      },
      (step) => setStatus(`Step 1/2 (transfer Pinto): ${step}`),
    )
    await runSeedOnly((step) => setStatus(`Step 2/2 (book into Silo): ${step}`))
    setStatus("Seeded Pinto into the Silo!", "ok")
    $("#s-amount").value = ""
    await loadCoin()
  } catch (err) {
    setStatus(friendlyError(err), "err")
  } finally {
    state.busy = false
    $("#s-submit").disabled = false
  }
})

// Chart controls & copy address
document.querySelectorAll(".c-range").forEach((b) => {
  b.addEventListener("click", () => {
    state.range = b.dataset.range
    document.querySelectorAll(".c-range").forEach((x) => x.setAttribute("aria-pressed", String(x === b)))
    loadCoin()
  })
})
document.querySelectorAll(".c-unit").forEach((b) => {
  b.addEventListener("click", () => {
    state.unit = b.dataset.unit
    document.querySelectorAll(".c-unit").forEach((x) => x.setAttribute("aria-pressed", String(x === b)))
    renderChart()
  })
})
$("#copy-addr")?.addEventListener("click", async () => {
  if (!state.coinAddr) return
  const btn = $("#copy-addr")
  try {
    await navigator.clipboard.writeText(state.coinAddr)
    btn.textContent = "Copied"
    setTimeout(() => (btn.textContent = "Copy address"), 1800)
  } catch {}
})

onWallet(() => refreshBalances())
setInterval(updateTollBanner, 1000)
setInterval(() => {
  if (!document.hidden && !state.busy) loadCoin()
}, 15_000)

loadCoin()
