import { BASESCAN, CHIRP, FACTORY, IS_TEST_FACTORY } from "./launcher-config.js"
import { createAvatarEl, fmtPinto, fmtTokenAmount, fmtUsd, fmtWeth, relTime, shortAddr } from "./launcher-core.js"
import { initWalletButton } from "./launcher-wallet.js"

const CHIRP_LAUNCHED_AT = 1794873600 // 2026-11-17 UTC

/** Formats 18-decimal veChirp weight / gauge share for a coin row. */
export function formatVeCell(coin, stakeSnap) {
  if (!stakeSnap || !stakeSnap.active) return { main: "—", sub: "gauge" }
  const totalW = BigInt(stakeSnap.silo?.totalWeightToday || "0")
  if (coin.mode === "flagship") {
    const locked = BigInt(stakeSnap.silo?.totalLockedChirp || "0")
    if (locked <= 0n) return { main: "0 CHIRP", sub: "locked in veChirp" }
    const totalWStr = totalW > 0n ? `${fmtTokenAmount(String(totalW))} total veChirp` : "activates next UTC day"
    return { main: `${fmtTokenAmount(String(locked))} locked`, sub: totalWStr }
  }
  const rawW = stakeSnap.coinWeights?.[String(coin.coin || "").toLowerCase()] || "0"
  const w = BigInt(rawW)
  if (w <= 0n) return { main: "0 veChirp", sub: "0% gauge" }
  const pct = totalW > 0n ? (Number((w * 10000n) / totalW) / 100) : 0
  const pctStr = pct >= 99.95 ? "100%" : `${pct.toFixed(1)}%`
  return { main: `${fmtTokenAmount(String(w))} veChirp`, sub: `${pctStr} gauge` }
}

/** Builds a coins-table entry for flagship CHIRP from the live /api/chirp snapshot. */
export function buildChirpEntry(snap) {
  const pintoUsd = Number(snap?.pintoUsd || 0)
  const priceUsd = Number(snap?.chirpUsd || 0)
  let supplyNum = 1_000_000_000
  try {
    if (snap?.field?.supply) supplyNum = Number(BigInt(snap.field.supply) / 10n ** 12n) / 1e6
  } catch {}
  let siloPintoNum = 0
  try {
    if (snap?.field?.silo) siloPintoNum = Number(BigInt(snap.field.silo)) / 1e6
  } catch {}
  let volPinto = 0
  try {
    if (snap?.stats?.volumePinto) volPinto = Number(BigInt(snap.stats.volumePinto)) / 1e6
  } catch {}
  const trades = Number(snap?.stats?.trades || 0)

  return {
    coin: CHIRP,
    name: "Chirp",
    symbol: "CHIRP",
    localIcon: "/chirp-icon-512.png",
    href: "/chirp",
    mode: "flagship",
    priceUsd,
    priceWeth: 0,
    fdvUsd: priceUsd > 0 ? priceUsd * supplyNum : 0,
    fdvWeth: 0,
    vol24hUsd: volPinto > 0 && pintoUsd > 0 ? volPinto * pintoUsd : 0,
    vol24hWeth: 0,
    volPinto,
    trades24h: trades,
    isAllTimeVol: true,
    siloPintoNum,
    siloPintoUsd: siloPintoNum > 0 && pintoUsd > 0 ? siloPintoNum * pintoUsd : 0,
    launchedAt: CHIRP_LAUNCHED_AT,
  }
}

export function matchesChirpQuery(q) {
  if (!q) return true
  const s = q.toLowerCase()
  return "chirp".includes(s) || "flagship".includes(s) || CHIRP.toLowerCase().includes(s)
}

function boot() {
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

  const tbody = document.querySelector("#coins-body")
  const metaEl = document.querySelector("#coins-meta")
  const moreBtn = document.querySelector("#coins-more")
  const searchInput = document.querySelector("#coins-search")
  if (!tbody) return

  let sort = "activity"
  let query = ""
  let offset = 0
  let total = 0
  let loaded = []
  let chirpSnap = null
  let stakeSnap = null
  let reqId = 0

  function createCoinAvatar(c) {
    if (c.localIcon) {
      const wrap = document.createElement("span")
      wrap.className = "l-avatar"
      const img = document.createElement("img")
      img.src = c.localIcon
      img.alt = `${c.symbol} logo`
      img.loading = "lazy"
      wrap.appendChild(img)
      return wrap
    }
    return createAvatarEl(c.imageUri, c.coin, c.symbol)
  }

  function renderRows(coins) {
    tbody.textContent = ""
    if (!coins.length) {
      const tr = document.createElement("tr")
      const td = document.createElement("td")
      td.colSpan = 7
      td.className = "l-empty"
      td.textContent = query ? "No coins match that search." : "No coins launched on this factory yet."
      tr.appendChild(td)
      tbody.appendChild(tr)
      return
    }

    for (const c of coins) {
      const tr = document.createElement("tr")
      tr.className = c.mode === "flagship" ? "l-row flagship" : "l-row"
      tr.tabIndex = 0
      const dest = c.href || `/coin?a=${encodeURIComponent(c.coin)}`
      const go = () => {
        window.location.href = dest
      }
      tr.addEventListener("click", go)
      tr.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault()
          go()
        }
      })

      // Coin column
      const tdCoin = document.createElement("td")
      const cell = document.createElement("div")
      cell.className = "l-coin-cell"
      cell.appendChild(createCoinAvatar(c))
      const names = document.createElement("div")
      const nEl = document.createElement("div")
      nEl.className = "l-coin-name"
      nEl.textContent = c.name || "Unnamed"
      const sEl = document.createElement("div")
      sEl.className = "l-coin-sym"
      sEl.textContent = `${c.symbol || "—"} · ${shortAddr(c.coin)}`
      names.append(nEl, sEl)
      cell.appendChild(names)
      tdCoin.appendChild(cell)

      // Mode column
      const tdMode = document.createElement("td")
      const badge = document.createElement("span")
      if (c.mode === "flagship") {
        badge.className = "l-badge flagship"
        badge.textContent = "Flagship"
      } else {
        badge.className = `l-badge ${c.mode === "redeem" ? "redeem" : ""}`.trim()
        badge.textContent = c.mode === "redeem" ? "Redeem" : "Burn"
      }
      tdMode.appendChild(badge)

      // Price / FDV
      const tdPrice = document.createElement("td")
      tdPrice.className = "l-num"
      tdPrice.textContent = c.priceUsd > 0 ? fmtUsd(c.priceUsd) : c.priceWeth > 0 ? fmtWeth(c.priceWeth) : "—"
      const fdvSub = document.createElement("span")
      fdvSub.className = "l-sub"
      fdvSub.textContent = c.fdvUsd > 0 ? `FDV ${fmtUsd(c.fdvUsd)}` : c.fdvWeth > 0 ? `FDV ${fmtWeth(c.fdvWeth)}` : "One-sided book"
      tdPrice.appendChild(fdvSub)

      // Volume
      const tdVol = document.createElement("td")
      tdVol.className = "l-num"
      if (c.isAllTimeVol) {
        tdVol.textContent = c.vol24hUsd > 0 ? fmtUsd(c.vol24hUsd) : c.volPinto > 0 ? fmtPinto(c.volPinto) : "—"
      } else {
        tdVol.textContent = c.vol24hUsd > 0 ? fmtUsd(c.vol24hUsd) : fmtWeth(c.vol24hWeth)
      }
      const trSub = document.createElement("span")
      trSub.className = "l-sub"
      trSub.textContent = c.isAllTimeVol
        ? `${c.trades24h} total trade${c.trades24h === 1 ? "" : "s"}`
        : `${c.trades24h} trade${c.trades24h === 1 ? "" : "s"}`
      tdVol.appendChild(trSub)

      // Silo Pinto
      const tdPinto = document.createElement("td")
      tdPinto.className = "l-num"
      tdPinto.textContent = c.siloPintoNum > 0 ? fmtPinto(c.siloPintoNum) : "0 Pinto"
      const pSub = document.createElement("span")
      pSub.className = "l-sub"
      pSub.textContent = c.siloPintoUsd > 0 ? fmtUsd(c.siloPintoUsd) : "in Silo"
      tdPinto.appendChild(pSub)

      // veChirp staked
      const tdVe = document.createElement("td")
      tdVe.className = "l-num"
      const veInfo = formatVeCell(c, stakeSnap)
      tdVe.textContent = veInfo.main
      const veSub = document.createElement("span")
      veSub.className = "l-sub"
      veSub.textContent = veInfo.sub
      tdVe.appendChild(veSub)

      // Launched
      const tdTime = document.createElement("td")
      tdTime.className = "l-num"
      tdTime.textContent = relTime(c.launchedAt)

      tr.append(tdCoin, tdMode, tdPrice, tdVol, tdPinto, tdVe, tdTime)
      tbody.appendChild(tr)
    }
  }

  async function loadCoins(append = false) {
    const mine = ++reqId
    if (!append) {
      offset = 0
      loaded = []
    }
    try {
      const params = new URLSearchParams({ sort, limit: "50", offset: String(offset) })
      if (query) params.set("q", query)

      const [res, chirpRes, stakeRes] = await Promise.all([
        fetch(`/api/launcher/coins?${params}`),
        !append && !chirpSnap ? fetch("/api/chirp").catch(() => null) : Promise.resolve(null),
        !append && !stakeSnap ? fetch("/api/launcher/stake").catch(() => null) : Promise.resolve(null),
      ])
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.json()
      if (chirpRes && chirpRes.ok) {
        chirpSnap = await chirpRes.json().catch(() => chirpSnap)
      }
      if (stakeRes && stakeRes.ok) {
        stakeSnap = await stakeRes.json().catch(() => stakeSnap)
      }
      if (mine !== reqId) return

      total = data.total ?? 0
      const batch = data.coins ?? []
      loaded = append ? [...loaded, ...batch] : batch
      offset = loaded.length

      const includeChirp = matchesChirpQuery(query)
      const rows = includeChirp ? [buildChirpEntry(chirpSnap), ...loaded] : loaded
      renderRows(rows)

      if (metaEl) {
        const displayTotal = total + (includeChirp ? 1 : 0)
        const pintoUsd = data.pintoUsd > 0 ? data.pintoUsd : Number(chirpSnap?.pintoUsd || 0)
        const ref = pintoUsd > 0 ? ` · Pinto ${fmtUsd(pintoUsd)}` : ""
        metaEl.textContent = `Showing ${rows.length} of ${displayTotal} coin${displayTotal === 1 ? "" : "s"}${ref}`
      }
      if (moreBtn) moreBtn.hidden = loaded.length >= total
    } catch {
      if (mine !== reqId) return
      // Even if launcher API fails, still render flagship Chirp when query matches.
      if (matchesChirpQuery(query)) {
        renderRows([buildChirpEntry(chirpSnap)])
        if (metaEl) metaEl.textContent = "Showing flagship Chirp · launcher coins temporarily unavailable."
        return
      }
      tbody.textContent = ""
      const tr = document.createElement("tr")
      const td = document.createElement("td")
      td.colSpan = 7
      td.className = "l-empty"
      td.textContent = "Could not load coins right now. Try refreshing in a moment."
      tr.appendChild(td)
      tbody.appendChild(tr)
    }
  }

  document.querySelectorAll(".sort-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      sort = btn.dataset.sort
      document.querySelectorAll(".sort-btn").forEach((b) => b.setAttribute("aria-pressed", String(b === btn)))
      loadCoins(false)
    })
  })

  let searchTimer = null
  searchInput?.addEventListener("input", () => {
    clearTimeout(searchTimer)
    searchTimer = setTimeout(() => {
      query = searchInput.value.trim()
      loadCoins(false)
    }, 220)
  })

  moreBtn?.addEventListener("click", () => loadCoins(true))

  loadCoins(false)
}

if (typeof document !== "undefined") boot()
