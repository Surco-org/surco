import { erc20Abi, formatUnits, getAddress, isAddress, parseUnits } from "viem"
import {
  BASESCAN,
  CHIRP,
  COLLECTIVE_SILO,
  COLLECTIVE_SILO_ABI,
  FACTORY,
  HAS_COLLECTIVE_SILO,
  IS_TEST_FACTORY,
  PINTO,
  VE_CHIRP,
  VE_CHIRP_ABI,
  VE_MAX_DAYS,
  VE_MIN_DAYS,
} from "./launcher-config.js"
import { fmtPinto, fmtTokenAmount, fmtUsd, fmtWeiEth, shortAddr, veWeightAt } from "./launcher-core.js"
import {
  connectWallet,
  ensureErc20Approval,
  friendlyError,
  getWallet,
  initWalletButton,
  onWallet,
  publicClient,
  sendSimulatedWrite,
} from "./launcher-wallet.js"

initWalletButton("#connect")

const $ = (s) => document.querySelector(s)
const banner = $("#test-banner")
const factoryLink = $("#test-factory-link")
if (IS_TEST_FACTORY && banner) {
  banner.hidden = false
  if (factoryLink) {
    factoryLink.href = `${BASESCAN}/address/${FACTORY}`
    factoryLink.textContent = `Factory ${shortAddr(FACTORY)}`
  }
}

const params = new URLSearchParams(window.location.search)
const preselectCoin = (params.get("coin") || "").trim().toLowerCase()

const state = {
  active: HAS_COLLECTIVE_SILO && isAddress(VE_CHIRP) && isAddress(COLLECTIVE_SILO),
  coins: [],
  coinByAddr: new Map(),
  stakeData: null,
  chirpBal: 0n,
  busy: false,
}

function setStatus(sel, msg, cls = "") {
  const el = $(sel)
  if (!el) return
  el.textContent = msg
  el.className = `l-status ${cls}`.trim()
}

function updateWeightPreview() {
  const perm = Boolean($("#lk-perm")?.checked)
  const days = Math.max(VE_MIN_DAYS, Math.min(VE_MAX_DAYS, Number($("#lk-days")?.value || 90)))
  $("#lk-days-wrap").hidden = perm
  $("#lk-days-val").textContent = `${days} day${days === 1 ? "" : "s"}`

  let amt = 0n
  try {
    const raw = $("#lk-amount").value.trim()
    if (raw) amt = parseUnits(raw, 18)
  } catch {
    amt = 0n
  }
  const multPct = perm ? 100 : (days / VE_MAX_DAYS) * 100
  $("#lk-mult-out").textContent = `${multPct.toFixed(1)}%`
  if (amt > 0n) {
    const w = veWeightAt(amt, days, perm)
    $("#lk-weight-out").textContent = `${fmtTokenAmount(String(w))} veCHIRP`
  } else {
    $("#lk-weight-out").textContent = "—"
  }
}

function applyActiveState() {
  const live = state.active && Boolean(state.stakeData?.active)
  $("#stake-preview-banner").hidden = live
  $("#lk-submit").disabled = !live
  $("#lk-submit").textContent = live ? "Lock Chirp" : "Activates with real factory"
  $("#cs-seed-btn").disabled = !live
}

function renderCoinSelect() {
  const sel = $("#lk-coin")
  if (!sel) return
  sel.textContent = ""
  if (!state.coins.length) {
    const opt = document.createElement("option")
    opt.value = ""
    opt.textContent = "No launcher coins indexed yet"
    sel.appendChild(opt)
    return
  }
  for (const c of state.coins) {
    const opt = document.createElement("option")
    opt.value = c.coin
    opt.textContent = `${c.symbol} — ${c.name} (${shortAddr(c.coin)})`
    if (preselectCoin && c.coin.toLowerCase() === preselectCoin) opt.selected = true
    sel.appendChild(opt)
  }
}

function renderSiloStats() {
  const s = state.stakeData?.silo
  if (!s) {
    $("#cs-silo").textContent = "—"
    $("#cs-yield").textContent = "—"
    $("#cs-weth").textContent = "—"
    $("#cs-locked").textContent = "—"
    $("#cs-weight").textContent = "—"
    $("#cs-nfts").textContent = "—"
    return
  }
  $("#cs-silo").textContent = `${fmtPinto(s.siloPintoNum)}${s.siloPintoUsd > 0 ? ` (${fmtUsd(s.siloPintoUsd)})` : ""}`
  $("#cs-yield").textContent = fmtPinto(Number(BigInt(s.yieldPinto || "0")) / 1e6)
  $("#cs-weth").textContent = fmtWeiEth(s.pendingWeth)
  $("#cs-locked").textContent = `${fmtTokenAmount(s.totalLockedChirp)} CHIRP`
  $("#cs-weight").textContent = `${fmtTokenAmount(s.totalWeightToday)} veCHIRP`
  $("#cs-nfts").textContent = String(s.totalLocks ?? 0)
}

function renderLocks() {
  const tbody = $("#locks-body")
  tbody.textContent = ""
  const { account } = getWallet()
  const note = $("#my-locks-note")
  if (!account) {
    note.textContent = "Connect a wallet to inspect and manage your veChirp locks."
  } else if (!state.active || !state.stakeData?.active) {
    note.textContent = `Wallet ${shortAddr(account)} connected — veChirp activates with the real factory.`
  } else {
    note.textContent = `Showing locks for ${shortAddr(account)}.`
  }

  const locks = state.stakeData?.locks || []
  if (!locks.length) {
    const tr = document.createElement("tr")
    const td = document.createElement("td")
    td.colSpan = 6
    td.className = "l-empty"
    td.textContent = account ? "No veChirp NFTs owned by this wallet yet." : "Connect a wallet to view your veChirp NFTs."
    tr.appendChild(td)
    tbody.appendChild(tr)
    return
  }

  for (const lk of locks) {
    const tr = document.createElement("tr")
    const tdId = document.createElement("td")
    tdId.className = "mono"
    tdId.textContent = `#${lk.id}`

    const tdCoin = document.createElement("td")
    const coinMeta = state.coinByAddr.get(lk.coin.toLowerCase())
    const a = document.createElement("a")
    a.href = `/coin?a=${encodeURIComponent(lk.coin)}`
    a.style.textDecoration = "underline"
    a.textContent = coinMeta ? `$${coinMeta.symbol}` : shortAddr(lk.coin)
    tdCoin.appendChild(a)

    const tdAmt = document.createElement("td")
    tdAmt.className = "l-num mono"
    tdAmt.textContent = `${fmtTokenAmount(lk.amount)} CHIRP`

    const tdW = document.createElement("td")
    tdW.className = "l-num mono"
    tdW.textContent = `${fmtTokenAmount(lk.weight)} veCHIRP`

    const tdSt = document.createElement("td")
    if (!lk.active) tdSt.textContent = "Withdrawn (past claims open)"
    else if (lk.permanent) tdSt.textContent = lk.pending ? "Pending · Permanent" : "Permanent (100%)"
    else if (lk.canWithdraw) tdSt.textContent = "Unlocked (ready to withdraw)"
    else tdSt.textContent = `${lk.pending ? "Pending · " : ""}${lk.remainingDays}d left`

    const tdAct = document.createElement("td")
    tdAct.className = "l-num"
    const bar = document.createElement("div")
    bar.style.display = "inline-flex"
    bar.style.gap = "6px"
    bar.style.flexWrap = "wrap"
    bar.style.justifyContent = "flex-end"

    const mkBtn = (label, onClick) => {
      const b = document.createElement("button")
      b.type = "button"
      b.className = "l-pill"
      b.textContent = label
      b.addEventListener("click", onClick)
      return b
    }

    bar.appendChild(mkBtn("Claim", () => runClaim(lk.id)))
    const curDay = Number(state.stakeData?.silo?.currentDay || 0)
    const canEdit = lk.permanent || (!lk.canWithdraw && (curDay > 0 ? lk.endDay > curDay + 1 : lk.remainingDays >= 2))
    if (lk.active) {
      if (canEdit && state.coins.length > 1) {
        bar.appendChild(mkBtn("Switch coin", () => runSwitchCoin(lk.id, lk.coin)))
      }
      if (canEdit) {
        bar.appendChild(mkBtn("Add Chirp", () => runAddAmount(lk.id)))
      }
      if (!lk.permanent) {
        bar.appendChild(mkBtn("Extend", () => runExtend(lk.id, lk.endDay)))
      }
      bar.appendChild(mkBtn(lk.permanent ? "Start 365d unlock" : "Max-lock", () => runSetPermanent(lk.id, !lk.permanent)))
      if (lk.canWithdraw) {
        bar.appendChild(mkBtn("Withdraw", () => runWithdraw(lk.id)))
      }
    }
    tdAct.appendChild(bar)

    tr.append(tdId, tdCoin, tdAmt, tdW, tdSt, tdAct)
    tbody.appendChild(tr)
  }
}

async function runSwitchCoin(lockId, currentCoin) {
  if (state.busy || !state.active) return
  const options = state.coins.filter((c) => c.coin.toLowerCase() !== currentCoin.toLowerCase())
  if (!options.length) {
    setStatus("#locks-status", "No other launched coins available to switch to.", "err")
    return
  }
  const listText = options.map((c, i) => `${i + 1}. ${c.symbol} (${shortAddr(c.coin)})`).join("\n")
  const pick = window.prompt(`Switch veChirp #${lockId} to which coin? Enter number or 0x address:\n${listText}`, "1")
  if (!pick) return
  const trimmed = pick.trim()
  let target = ""
  if (isAddress(trimmed)) {
    target = getAddress(trimmed)
  } else {
    const idx = Number(trimmed) - 1
    if (Number.isInteger(idx) && idx >= 0 && idx < options.length) target = getAddress(options[idx].coin)
  }
  if (!target) {
    setStatus("#locks-status", "Invalid coin selection.", "err")
    return
  }
  state.busy = true
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    await sendSimulatedWrite(
      {
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "switchCoin",
        args: [BigInt(lockId), target],
      },
      (m) => setStatus("#locks-status", `Switch #${lockId}: ${m}`),
    )
    setStatus("#locks-status", `veChirp #${lockId} switched coin (takes effect 00:00 UTC tomorrow).`, "ok")
    await loadAll()
  } catch (err) {
    setStatus(
      "#locks-status",
      friendlyError(err, {
        SameCoin: "Already backing that coin.",
        UnknownCoin: "Coin not registered on this factory.",
        BadDuration: "Lock expires tomorrow or earlier; extend before switching coins.",
      }),
      "err",
    )
  } finally {
    state.busy = false
  }
}

async function runAddAmount(lockId) {
  if (state.busy || !state.active) return
  const raw = window.prompt(`Add how much CHIRP to veChirp #${lockId}?`, "100")
  if (!raw) return
  let amt
  try {
    amt = parseUnits(raw.trim(), 18)
    if (amt <= 0n || amt > (1n << 128n) - 1n) throw new Error()
  } catch {
    setStatus("#locks-status", "Enter a valid Chirp amount.", "err")
    return
  }
  state.busy = true
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    await ensureErc20Approval(CHIRP, getAddress(VE_CHIRP), amt, (m) => setStatus("#locks-status", `Add #${lockId}: ${m}`))
    await sendSimulatedWrite(
      {
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "addAmount",
        args: [BigInt(lockId), amt],
      },
      (m) => setStatus("#locks-status", `Add #${lockId}: ${m}`),
    )
    setStatus("#locks-status", `Added CHIRP to veChirp #${lockId} (takes effect 00:00 UTC tomorrow).`, "ok")
    await loadAll()
  } catch (err) {
    setStatus("#locks-status", friendlyError(err, { BadDuration: "Cannot add to an expired lock." }), "err")
  } finally {
    state.busy = false
  }
}

async function runExtend(lockId, currentEndDay) {
  if (state.busy || !state.active) return
  const raw = window.prompt(`Extend veChirp #${lockId} to how many total UTC days from tomorrow (${VE_MIN_DAYS}–${VE_MAX_DAYS})?`, "180")
  if (!raw) return
  const days = Math.floor(Number(raw.trim()))
  if (!Number.isFinite(days) || days < VE_MIN_DAYS || days > VE_MAX_DAYS) {
    setStatus("#locks-status", `Enter between ${VE_MIN_DAYS} and ${VE_MAX_DAYS} days.`, "err")
    return
  }
  state.busy = true
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    const today = Number(
      await publicClient.readContract({
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "currentDay",
      }),
    )
    const newEndDay = today + 1 + days
    if (newEndDay <= currentEndDay) {
      setStatus("#locks-status", "New unlock day must be later than the current unlock day.", "err")
      return
    }
    await sendSimulatedWrite(
      {
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "extend",
        args: [BigInt(lockId), newEndDay],
      },
      (m) => setStatus("#locks-status", `Extend #${lockId}: ${m}`),
    )
    setStatus("#locks-status", `Extended veChirp #${lockId} (takes effect 00:00 UTC tomorrow).`, "ok")
    await loadAll()
  } catch (err) {
    setStatus("#locks-status", friendlyError(err, { BadDuration: "New end day must be strictly later and within 365 days." }), "err")
  } finally {
    state.busy = false
  }
}

async function runClaim(lockId) {
  if (state.busy || !state.active) return
  state.busy = true
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    setStatus("#locks-status", `Checking claimable rewards for veChirp #${lockId}…`)
    const { result } = await publicClient.simulateContract({
      account,
      address: getAddress(COLLECTIVE_SILO),
      abi: COLLECTIVE_SILO_ABI,
      functionName: "claim",
      args: [BigInt(lockId), 60],
    })
    const [claimCoin, payout] = result
    if (!payout || payout === 0n) {
      setStatus("#locks-status", `No settled rewards ready to claim for veChirp #${lockId} yet.`)
      return
    }
    await sendSimulatedWrite(
      {
        address: getAddress(COLLECTIVE_SILO),
        abi: COLLECTIVE_SILO_ABI,
        functionName: "claim",
        args: [BigInt(lockId), 60],
      },
      (m) => setStatus("#locks-status", `Claim #${lockId}: ${m}`),
    )
    const meta = state.coinByAddr.get(String(claimCoin).toLowerCase())
    const sym = meta ? meta.symbol : shortAddr(claimCoin)
    setStatus("#locks-status", `Claimed ${fmtTokenAmount(String(payout))} ${sym} for veChirp #${lockId}!`, "ok")
    await loadAll()
  } catch (err) {
    setStatus("#locks-status", friendlyError(err, { NotClaimant: "Only the NFT owner can claim." }), "err")
  } finally {
    state.busy = false
  }
}

async function runSetPermanent(lockId, on) {
  if (state.busy || !state.active) return
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    state.busy = true
    await sendSimulatedWrite(
      {
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "setPermanent",
        args: [BigInt(lockId), on],
      },
      (m) => setStatus("#locks-status", `veChirp #${lockId}: ${m}`),
    )
    setStatus("#locks-status", on ? `veChirp #${lockId} set to Permanent Max-Lock (effective 00:00 UTC).` : `veChirp #${lockId} 365-day unlock started (effective 00:00 UTC).`, "ok")
    await loadAll()
  } catch (err) {
    setStatus("#locks-status", friendlyError(err), "err")
  } finally {
    state.busy = false
  }
}

async function runWithdraw(lockId) {
  if (state.busy || !state.active) return
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    state.busy = true
    await sendSimulatedWrite(
      {
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "withdraw",
        args: [BigInt(lockId)],
      },
      (m) => setStatus("#locks-status", `Withdraw #${lockId}: ${m}`),
    )
    setStatus("#locks-status", `Withdrew Chirp from veChirp #${lockId}!`, "ok")
    await loadAll()
  } catch (err) {
    setStatus("#locks-status", friendlyError(err, { StillLocked: "Lock has not expired yet." }), "err")
  } finally {
    state.busy = false
  }
}

async function refreshBalance() {
  const { account } = getWallet()
  if (!account) {
    state.chirpBal = 0n
    $("#lk-bal").textContent = "Balance: —"
    return
  }
  try {
    const bal = await publicClient.readContract({
      address: CHIRP,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    })
    state.chirpBal = bal
    $("#lk-bal").textContent = `Balance: ${fmtTokenAmount(String(bal))} CHIRP`
  } catch {}
}

async function loadAll() {
  const { account } = getWallet()
  try {
    const [coinsRes, stakeRes] = await Promise.all([
      fetch("/api/launcher/coins?sort=backing&limit=100"),
      fetch(account ? `/api/launcher/stake?a=${encodeURIComponent(account)}` : "/api/launcher/stake"),
    ])
    const coinsData = await coinsRes.json().catch(() => ({}))
    const stakeData = await stakeRes.json().catch(() => ({}))
    state.coins = coinsData.coins || []
    state.coinByAddr = new Map(state.coins.map((c) => [c.coin.toLowerCase(), c]))
    state.stakeData = stakeData
  } catch {}
  renderCoinSelect()
  renderSiloStats()
  renderLocks()
  applyActiveState()
  refreshBalance()
}

// Form & slider listeners
$("#lk-amount")?.addEventListener("input", updateWeightPreview)
$("#lk-days")?.addEventListener("input", updateWeightPreview)
$("#lk-perm")?.addEventListener("change", updateWeightPreview)
document.querySelectorAll(".lk-preset").forEach((btn) => {
  btn.addEventListener("click", () => {
    $("#lk-perm").checked = false
    $("#lk-days").value = btn.dataset.days
    updateWeightPreview()
  })
})
$("#lk-max")?.addEventListener("click", () => {
  $("#lk-amount").value = state.chirpBal > 0n ? formatUnits(state.chirpBal, 18) : ""
  updateWeightPreview()
})

$("#lock-form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  if (state.busy || !state.active) return
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    const amt = parseUnits($("#lk-amount").value.trim() || "0", 18)
    if (amt < 365n || amt > (1n << 128n) - 1n) {
      setStatus("#lk-status", "Enter a valid Chirp amount to lock (minimum 365 wei).", "err")
      return
    }
    const coinRaw = $("#lk-coin").value.trim()
    if (!isAddress(coinRaw)) {
      setStatus("#lk-status", "Select a factory-launched coin to back.", "err")
      return
    }
    const perm = Boolean($("#lk-perm").checked)
    const days = perm ? 0 : Math.max(VE_MIN_DAYS, Math.min(VE_MAX_DAYS, Math.floor(Number($("#lk-days").value || 90))))

    state.busy = true
    $("#lk-submit").disabled = true
    await ensureErc20Approval(CHIRP, getAddress(VE_CHIRP), amt, (m) => setStatus("#lk-status", m))
    await sendSimulatedWrite(
      {
        address: getAddress(VE_CHIRP),
        abi: VE_CHIRP_ABI,
        functionName: "lock",
        args: [amt, days, perm, getAddress(coinRaw)],
      },
      (m) => setStatus("#lk-status", m),
    )
    setStatus("#lk-status", "veChirp NFT minted! Your weight activates at 00:00 UTC tomorrow.", "ok")
    $("#lk-amount").value = ""
    updateWeightPreview()
    await loadAll()
  } catch (err) {
    setStatus(
      "#lk-status",
      friendlyError(err, {
        ZeroAmount: "Minimum lock is 365 wei of CHIRP.",
        BadDuration: "Lock duration must be between 2 and 365 days.",
        UnknownCoin: "That coin is not registered on this factory.",
      }),
      "err",
    )
  } finally {
    state.busy = false
    applyActiveState()
  }
})

$("#cs-seed-form")?.addEventListener("submit", async (e) => {
  e.preventDefault()
  if (state.busy || !state.active) return
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()
    const amt = parseUnits($("#cs-seed-amt").value.trim() || "0", 6)
    if (amt <= 0n) {
      setStatus("#cs-seed-status", "Enter a Pinto amount to seed.", "err")
      return
    }
    state.busy = true
    $("#cs-seed-btn").disabled = true
    await sendSimulatedWrite(
      {
        address: PINTO,
        abi: erc20Abi,
        functionName: "transfer",
        args: [getAddress(COLLECTIVE_SILO), amt],
      },
      (m) => setStatus("#cs-seed-status", `Step 1/2 (transfer Pinto): ${m}`),
    )
    await sendSimulatedWrite(
      {
        address: getAddress(COLLECTIVE_SILO),
        abi: COLLECTIVE_SILO_ABI,
        functionName: "seed",
      },
      (m) => setStatus("#cs-seed-status", `Step 2/2 (book into Silo): ${m}`),
    )
    setStatus("#cs-seed-status", "Seeded Pinto into the Collective Silo!", "ok")
    $("#cs-seed-amt").value = ""
    await loadAll()
  } catch (err) {
    setStatus("#cs-seed-status", friendlyError(err), "err")
  } finally {
    state.busy = false
    applyActiveState()
  }
})

onWallet(() => loadAll())
updateWeightPreview()
loadAll()
