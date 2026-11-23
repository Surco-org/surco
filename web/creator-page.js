import { getAddress, isAddress } from "viem"
import { BASESCAN, FACTORY, IS_TEST_FACTORY, VAULT_ABI } from "./launcher-config.js"
import { createAvatarEl, fmtUsd, fmtWeiEth, shortAddr } from "./launcher-core.js"
import { connectWallet, friendlyError, getWallet, initWalletButton, onWallet, sendSimulatedWrite } from "./launcher-wallet.js"

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
const addrInput = $("#creator-addr")
const statusEl = $("#creator-status")
const tbody = $("#creator-body")
const summaryEl = $("#creator-summary")

let activeAddr = ""
let busy = false

function setStatus(msg, cls = "") {
  statusEl.textContent = msg
  statusEl.className = `l-status ${cls}`.trim()
}

function renderCoins(data) {
  summaryEl.hidden = false
  $("#c-paid").textContent = `${fmtWeiEth(data.totals.paidWeth)}${data.totals.paidUsd > 0 ? ` (${fmtUsd(data.totals.paidUsd)})` : ""}`
  $("#c-claimable").textContent = `${fmtWeiEth(data.totals.claimableWeth)}${data.totals.claimableUsd > 0 ? ` (${fmtUsd(data.totals.claimableUsd)})` : ""}`
  $("#c-count").textContent = String(data.coins.length)

  tbody.textContent = ""
  if (!data.coins.length) {
    const tr = document.createElement("tr")
    const td = document.createElement("td")
    td.colSpan = 6
    td.className = "l-empty"
    td.textContent = "No launcher coins found for this address."
    tr.appendChild(td)
    tbody.appendChild(tr)
    return
  }

  const walletLc = getWallet().account?.toLowerCase() || ""

  for (const c of data.coins) {
    const tr = document.createElement("tr")

    // Coin link
    const tdCoin = document.createElement("td")
    const a = document.createElement("a")
    a.href = `/coin?a=${encodeURIComponent(c.coin)}`
    a.className = "l-coin-cell"
    a.appendChild(createAvatarEl(c.imageUri, c.coin, c.symbol))
    const names = document.createElement("div")
    const nEl = document.createElement("div")
    nEl.className = "l-coin-name"
    nEl.textContent = c.name || "Unnamed"
    const sEl = document.createElement("div")
    sEl.className = "l-coin-sym"
    sEl.textContent = `${c.symbol}${c.isCurrentPayout ? "" : ` · payout → ${shortAddr(c.creatorPayout)}`}`
    names.append(nEl, sEl)
    a.appendChild(names)
    tdCoin.appendChild(a)

    // Mode
    const tdMode = document.createElement("td")
    const badge = document.createElement("span")
    badge.className = `l-badge ${c.mode === "redeem" ? "redeem" : ""}`.trim()
    badge.textContent = c.mode === "redeem" ? "Redeem" : "Burn"
    tdMode.appendChild(badge)

    // Share
    const tdShare = document.createElement("td")
    tdShare.className = "l-num"
    tdShare.textContent = `${(c.creatorBps / 100).toFixed(0)}%`

    // Paid
    const tdPaid = document.createElement("td")
    tdPaid.className = "l-num"
    tdPaid.textContent = fmtWeiEth(c.creatorPaidWeth)

    // Claimable
    const tdClaim = document.createElement("td")
    tdClaim.className = "l-num"
    const claimWei = BigInt(c.claimableCreatorWeth || "0")
    tdClaim.textContent = fmtWeiEth(c.claimableCreatorWeth)

    // Actions
    const tdAct = document.createElement("td")
    tdAct.className = "l-num"
    const wrap = document.createElement("div")
    wrap.style.display = "flex"
    wrap.style.gap = "8px"
    wrap.style.justifyContent = "flex-end"
    wrap.style.flexWrap = "wrap"

    const splitBtn = document.createElement("button")
    splitBtn.type = "button"
    splitBtn.className = "btn btn-primary"
    splitBtn.style.padding = "6px 12px"
    splitBtn.style.fontSize = "13px"
    splitBtn.textContent = "Claim WETH"
    splitBtn.disabled = claimWei === 0n
    splitBtn.addEventListener("click", async () => {
      if (busy) return
      try {
        if (!getWallet().account) await connectWallet()
        busy = true
        splitBtn.disabled = true
        await sendSimulatedWrite(
          { address: getAddress(c.vault), abi: VAULT_ABI, functionName: "split" },
          setStatus,
        )
        setStatus(`Split confirmed for ${c.symbol}! WETH sent to ${shortAddr(c.creatorPayout)}.`, "ok")
        await loadCreator(activeAddr)
      } catch (err) {
        setStatus(friendlyError(err), "err")
      } finally {
        busy = false
        splitBtn.disabled = false
      }
    })
    wrap.appendChild(splitBtn)

    if (c.isCurrentPayout && walletLc === c.creatorPayout.toLowerCase()) {
      const changeBtn = document.createElement("button")
      changeBtn.type = "button"
      changeBtn.className = "btn btn-ghost"
      changeBtn.style.padding = "6px 12px"
      changeBtn.style.fontSize = "13px"
      changeBtn.textContent = "Change payout"
      changeBtn.addEventListener("click", () => {
        const nextRaw = window.prompt(
          `Hand off future ${c.symbol} creator fees to a new 0x address?\n\nWarning: the new address immediately owns future WETH payouts and control.`,
        )
        if (!nextRaw) return
        const trimmed = nextRaw.trim()
        if (!isAddress(trimmed)) {
          setStatus("Invalid 0x address.", "err")
          return
        }
        ;(async () => {
          if (busy) return
          try {
            busy = true
            await sendSimulatedWrite(
              {
                address: getAddress(c.vault),
                abi: VAULT_ABI,
                functionName: "setCreatorPayout",
                args: [getAddress(trimmed)],
              },
              setStatus,
            )
            setStatus(`Creator payout updated to ${shortAddr(trimmed)}.`, "ok")
            await loadCreator(activeAddr)
          } catch (err) {
            setStatus(friendlyError(err, { OnlyCreator: "Only the current payout wallet can change this." }), "err")
          } finally {
            busy = false
          }
        })()
      })
      wrap.appendChild(changeBtn)
    }

    tdAct.appendChild(wrap)
    tr.append(tdCoin, tdMode, tdShare, tdPaid, tdClaim, tdAct)
    tbody.appendChild(tr)
  }
}

async function loadCreator(addr) {
  if (!isAddress(addr)) {
    setStatus("Enter a valid 0x address.", "err")
    return
  }
  activeAddr = getAddress(addr)
  addrInput.value = activeAddr
  setStatus("Loading creator data…")
  try {
    const res = await fetch(`/api/launcher/creator?a=${encodeURIComponent(activeAddr)}`)
    const data = await res.json().catch(() => ({}))
    if (!res.ok) {
      setStatus(data.error || "Could not load creator data.", "err")
      return
    }
    setStatus("")
    renderCoins(data)
  } catch {
    setStatus("Could not reach /api/launcher/creator.", "err")
  }
}

$("#creator-lookup")?.addEventListener("submit", (e) => {
  e.preventDefault()
  loadCreator(addrInput.value.trim())
})

const qAddr = new URLSearchParams(window.location.search).get("a")
if (qAddr && isAddress(qAddr)) {
  loadCreator(qAddr)
}

onWallet(({ account }) => {
  if (account && !activeAddr) {
    loadCreator(account)
  } else if (activeAddr) {
    // Re-render to show/hide "Change payout" if connected wallet matches
    loadCreator(activeAddr)
  }
})
