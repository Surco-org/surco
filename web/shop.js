import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  custom,
  erc20Abi,
  getAddress,
  http,
  isAddress,
  parseAbi,
} from "viem"
import { base } from "viem/chains"
import { HOOK as HOOK_RAW } from "./config.js"
import {
  OPENING,
  applySlippage,
  buyFeeBps,
  formatAmount,
  formatFee,
  parseAmount,
  priceRaw,
  quoteBuy,
  quoteSell,
  TOLL_WINDOW,
} from "./quote.js"
import { ALLOWANCE_HOLDER, COINS, maxSpend, received, zeroX } from "./coins.js"
import { onLive } from "./live.js"

const HOOK = isAddress(HOOK_RAW) ? getAddress(HOOK_RAW) : ""
const PINTO = getAddress(COINS.pinto.address)
const READ_URL = "https://base.publicnode.com"

const bookAbi = parseAbi([
  "function virtualPinto() view returns (uint256)",
  "function pintoInCurve() view returns (uint256)",
  "function chirpReserve() view returns (uint256)",
  "function tollStart() view returns (uint256)",
  "function opened() view returns (bool)",
  "function chirp() view returns (address)",
  "function pinto() view returns (address)",
  "error SellTooBig()",
  "error ZeroOut()",
  "error ZeroIn()",
  "error NotOpen()",
  "error ShortPull()",
  "error PullFailed()",
  "error ZeroAddress()",
])

const hookAbi = parseAbi([
  "function book() view returns (address)",
  "function swapExactPintoForChirp(uint256 pintoIn, uint256 minChirp, address recipient) returns (uint256)",
  "function swapExactChirpForPinto(uint256 chirpIn, uint256 minPinto, address recipient) returns (uint256)",
  "error Slippage()",
  "error PullFailed()",
  "error ApproveFailed()",
  "error Locked()",
  "error SellTooBig()",
  "error ZeroOut()",
  "error ZeroIn()",
  "error NotOpen()",
  "error ShortPull()",
  "error ZeroAddress()",
])

const REVERT = {
  Slippage: "The price moved past your slippage. Try again.",
  SellTooBig: "That sell asks for more Pinto than buyers have put in.",
  ZeroOut: "That amount is too small to trade.",
  PullFailed: "The coins did not move. Approve them and try again.",
  ApproveFailed: "The approval did not stick. Try again.",
  NotOpen: "The shop is not open yet.",
  Locked: "The shop is busy. Try again in a moment.",
  ShortPull: "The coins that arrived were short. Try again.",
  ZeroAddress: "The trade is missing a wallet.",
  ZeroIn: "Enter an amount first.",
}

const publicClient = createPublicClient({ chain: base, transport: http(READ_URL) })

const ui = {
  connect: document.querySelector("#connect"),
  price: document.querySelector("#price"),
  shelf: document.querySelector("#shelf"),
  buy: document.querySelector("#side-buy"),
  sell: document.querySelector("#side-sell"),
  amount: document.querySelector("#amount"),
  max: document.querySelector("#max"),
  payToken: document.querySelector("#pay-token"),
  out: document.querySelector("#out"),
  getToken: document.querySelector("#get-token"),
  fee: document.querySelector("#fee"),
  warn: document.querySelector("#warn"),
  go: document.querySelector("#go"),
  slip: document.querySelector("#slip"),
  slipNote: document.querySelector("#slip-note"),
  status: document.querySelector("#status"),
  hold: document.querySelector("#hold"),
  form: document.querySelector("#trade"),
  coin: document.querySelector("#coin"),
  coinLabel: document.querySelector("#coin-label"),
  route: document.querySelector("#route"),
  bal: document.querySelector("#bal"),
  navBal: document.querySelector("#nav-bal"),
}

const state = {
  side: "buy",
  slipBps: 100,
  book: null,
  tokens: null,
  account: null,
  chainId: null,
  pintoBal: null,
  chirpBal: null,
  coin: ui.coin?.value ?? "eth",
  coinBal: null,
  leg: null,
  busy: "",
  status: "",
  bad: false,
  readError: false,
}

function nowSec() {
  return BigInt(Math.floor(Date.now() / 1000))
}

function book() {
  return state.book ?? OPENING
}

function live() {
  return Boolean(HOOK && state.book?.opened)
}

function wallet() {
  return createWalletClient({ chain: base, transport: custom(window.ethereum) })
}

function short(addr) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

function coin() {
  return COINS[state.coin]
}

function viaZeroX() {
  return state.coin !== "pinto"
}

function legKey() {
  return `${state.side}|${state.coin}|${state.slipBps}|${ui.amount.value.trim()}`
}

function plainError(err) {
  if (err instanceof BaseError) {
    const rev = err.walk((e) => e instanceof ContractFunctionRevertedError)
    if (rev instanceof ContractFunctionRevertedError) {
      return REVERT[rev.data?.errorName] ?? "The trade did not go through."
    }
    if (err.walk((e) => e.name === "UserRejectedRequestError")) return "You closed the wallet."
  } else if (err instanceof Error && err.message && err.message !== "reverted") {
    return err.message
  }
  return "The trade did not go through."
}

function setStatus(text, bad = false) {
  state.status = text
  state.bad = bad
  ui.status.textContent = text
  ui.status.classList.toggle("bad", bad)
}

function quote() {
  const buying = state.side === "buy"
  const raw = parseAmount(ui.amount.value, buying ? coin().decimals : 18)
  if (raw == null || raw === 0n) return { empty: true }
  const current = book()
  const leg = state.leg?.key === legKey() ? state.leg : null
  if (buying) {
    let pintoIn = raw
    if (viaZeroX()) {
      if (!leg) return { raw, pending: true }
      if (leg.error) return { raw, bad: leg.error }
      pintoIn = leg.amount
    }
    const q = quoteBuy(current, pintoIn, nowSec())
    if (q.chirpOut === 0n) return { raw, bad: "That amount is too small to trade." }
    return { raw, pinto: pintoIn, feeBps: q.feeBps, out: q.chirpOut, min: applySlippage(q.chirpOut, state.slipBps) }
  }
  const q = quoteSell(current, raw)
  if (!q.ok && q.reason === "empty") {
    return { raw, bad: "Buys come first. A sell pays Pinto that buyers put in." }
  }
  if (!q.ok && q.reason === "big") {
    return { raw, bad: "That sell asks for more Pinto than buyers have put in." }
  }
  if (!q.ok) return { raw, bad: "That amount is too small to trade." }
  const min = applySlippage(q.paid, state.slipBps)
  if (!viaZeroX()) return { raw, feeBps: 100n, out: q.paid, min }
  if (!leg) return { raw, pinto: q.paid, min, pending: true }
  if (leg.error) return { raw, bad: leg.error }
  return { raw, feeBps: 100n, pinto: q.paid, out: leg.amount, min }
}

// The 0x leg is fetched apart from paint: a cheap /price preview, debounced, kept by input key.
let legTimer
function refreshLeg() {
  clearTimeout(legTimer)
  if (!viaZeroX()) return
  const key = legKey()
  const buying = state.side === "buy"
  const raw = parseAmount(ui.amount.value, buying ? coin().decimals : 18)
  if (raw == null || raw === 0n) return
  legTimer = setTimeout(async () => {
    let amount = raw
    if (!buying) {
      const q = quoteSell(book(), raw)
      if (!q.ok) return
      amount = applySlippage(q.paid, state.slipBps)
    }
    const c = coin()
    let leg
    try {
      const z = await zeroX("price", {
        sell: buying ? c.address : PINTO,
        buy: buying ? PINTO : c.address,
        amount,
        slipBps: state.slipBps,
      })
      leg = { key, amount: z.buyAmount }
    } catch (err) {
      leg = { key, error: err.message }
    }
    if (key === legKey()) {
      state.leg = leg
      paint()
    }
  }, 350)
}

function feeLine(feeBps) {
  const start = book().tollStart
  const elapsed = start === 0n ? TOLL_WINDOW : nowSec() - start
  if (start !== 0n && elapsed < TOLL_WINDOW) {
    const left = Number(TOLL_WINDOW - elapsed)
    const m = Math.floor(left / 60)
    const s = left % 60
    return `A buy pays ${formatFee(feeBps)} right now. A sell pays 1%. The buy fee reaches 1% in ${m}:${String(s).padStart(2, "0")}.`
  }
  if (!state.book) {
    return "Buys and sells pay 1%. For ten minutes after launch, a buy starts at 90% and falls to 1%."
  }
  return "Buys and sells pay 1%."
}

function balanceForSide() {
  if (state.side === "sell") return state.chirpBal
  return viaZeroX() ? state.coinBal : state.pintoBal
}

function paint() {
  const current = book()
  const price = priceRaw(current)
  ui.price.textContent = formatAmount(price, 6, 6)
  const chirpLeft = formatAmount(current.chirpReserve, 18, 0)
  const paidIn = formatAmount(current.pintoInCurve, 6, 2)
  const where = "Pinto from a buy stays in the silo. A sell pays Pinto back right away."
  if (!state.book) {
    ui.shelf.textContent = `${chirpLeft} Chirp are for sale. ${where} This is the opening price.`
  } else if (!live()) {
    ui.shelf.textContent = `${chirpLeft} Chirp are for sale. ${paidIn} Pinto paid in. ${where} The shop is not open yet.`
  } else {
    ui.shelf.textContent = `${chirpLeft} Chirp left for sale. ${paidIn} Pinto paid in. ${where}`
  }

  const buying = state.side === "buy"
  ui.buy.setAttribute("aria-selected", buying ? "true" : "false")
  ui.sell.setAttribute("aria-selected", buying ? "false" : "true")
  const sym = coin().symbol
  ui.coinLabel.textContent = buying ? "Pay with" : "Get paid in"
  ui.payToken.textContent = buying ? sym : "Chirp"
  ui.getToken.textContent = buying ? "Chirp" : sym

  const q = quote()
  const feeBps = buyFeeBps(current.tollStart, nowSec())
  ui.fee.textContent = feeLine(feeBps)
  ui.slipNote.textContent = `If the price moves more than ${formatFee(BigInt(state.slipBps))}, the trade stops`
  if (q.empty || q.bad) {
    ui.out.textContent = "0"
  } else if (q.pending) {
    ui.out.textContent = "…"
  } else {
    ui.out.textContent = formatAmount(q.out, buying ? 18 : coin().decimals, buying ? 4 : 6)
  }
  let route = ""
  if (viaZeroX() && !q.empty && !q.bad && q.pinto != null) {
    const p = formatAmount(q.pinto, 6, 2)
    route = buying
      ? `Swaps to about ${p} Pinto through 0x, then buys Chirp. Your wallet asks up to four times.`
      : `Sells for about ${p} Pinto, then swaps it to ${sym} through 0x. Your wallet asks up to three times.`
  }
  ui.route.hidden = !route
  ui.route.textContent = route

  const have = balanceForSide()
  let warn = q.bad ?? ""
  if (!warn && !q.empty && have != null && q.raw > have) {
    warn = `Your wallet does not have that much ${buying ? sym : "Chirp"}.`
  }
  ui.warn.hidden = !warn
  ui.warn.textContent = warn

  const onBase = state.chainId == null || state.chainId === base.id
  let go = "Buy Chirp"
  let disabled = false
  if (state.busy) {
    go = state.busy
    disabled = true
  } else if (!live()) {
    go = "Opens at launch"
    disabled = true
  } else if (!state.account) {
    go = "Connect wallet"
  } else if (!onBase) {
    go = "Switch to Base"
  } else if (q.empty || q.bad || q.pending || (have != null && q.raw > have) || q.min === 0n) {
    go = buying ? "Buy Chirp" : "Sell Chirp"
    disabled = true
  } else {
    go = buying ? "Buy Chirp" : "Sell Chirp"
  }
  ui.go.textContent = go
  for (const el of document.querySelectorAll(".net-pill, .swap-net")) {
    el.textContent = live() ? (el.classList.contains("net-pill") ? "Base · open" : "Open on Base") : el.classList.contains("net-pill") ? "Base · opens at launch" : "Opens at launch"
  }
  ui.go.disabled = disabled

  if (state.account) {
    const pinto = state.pintoBal == null ? "…" : formatAmount(state.pintoBal, 6, 2)
    ui.connect.textContent = short(state.account)
    const chirp = state.chirpBal == null ? "…" : formatAmount(state.chirpBal, 18, 2)
    const other = viaZeroX() ? `${state.coinBal == null ? "…" : formatAmount(state.coinBal, coin().decimals, 6)} ${sym}, ` : ""
    ui.hold.textContent = `Wallet holds ${other}${pinto} Pinto and ${chirp} Chirp.`
    ui.navBal.hidden = false
    ui.navBal.textContent = `${chirp} Chirp`
    const paySym = buying ? sym : "Chirp"
    const payDec = buying ? coin().decimals : 18
    ui.bal.textContent = have == null ? "" : `Balance ${formatAmount(have, payDec, !buying || payDec === 6 ? 2 : 6)} ${paySym}`
  } else {
    ui.navBal.hidden = true
    ui.bal.textContent = ""
    ui.connect.textContent = window.ethereum ? "Connect wallet" : "No wallet found"
    ui.hold.textContent = ""
  }
}

async function loadBook() {
  if (!HOOK) {
    state.readError = false
    paint()
    return
  }
  try {
    const bookAddr = await publicClient.readContract({ address: HOOK, abi: hookAbi, functionName: "book" })
    const names = ["virtualPinto", "pintoInCurve", "chirpReserve", "tollStart", "opened", "chirp", "pinto"]
    const rows = await publicClient.multicall({
      allowFailure: false,
      contracts: names.map((functionName) => ({ address: bookAddr, abi: bookAbi, functionName })),
    })
    state.book = {
      virtualPinto: rows[0],
      pintoInCurve: rows[1],
      chirpReserve: rows[2],
      tollStart: rows[3],
      opened: rows[4],
    }
    state.tokens = { chirp: rows[5], pinto: rows[6] }
    state.readError = false
  } catch {
    state.readError = true
    if (!state.busy) setStatus("The price could not be read. Refresh the page.", true)
  }
  paint()
}

async function loadBalances() {
  if (!state.account) return
  const pinto = state.tokens?.pinto ?? PINTO
  try {
    state.pintoBal = await publicClient.readContract({
      address: pinto,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [state.account],
    })
    if (state.tokens?.chirp) {
      state.chirpBal = await publicClient.readContract({
        address: state.tokens.chirp,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [state.account],
      })
    }
    const c = coin()
    state.coinBal = c.native
      ? await publicClient.getBalance({ address: state.account })
      : viaZeroX()
        ? await publicClient.readContract({ address: c.address, abi: erc20Abi, functionName: "balanceOf", args: [state.account] })
        : null
  } catch {
    state.pintoBal = null
    state.chirpBal = null
    state.coinBal = null
  }
  paint()
}

async function connect() {
  if (!window.ethereum) {
    setStatus("Open this page in a browser with a wallet.", true)
    return
  }
  try {
    const client = wallet()
    const [account] = await client.requestAddresses()
    state.account = getAddress(account)
    state.chainId = await client.getChainId()
    setStatus("")
    await loadBalances()
  } catch (err) {
    setStatus(plainError(err), true)
  }
}

async function switchToBase() {
  await window.ethereum.request({
    method: "wallet_switchEthereumChain",
    params: [{ chainId: "0x2105" }],
  })
  state.chainId = base.id
}

async function ensureAllowance(token, amount, spender = HOOK) {
  const allowance = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [state.account, spender],
  })
  if (allowance >= amount) return
  state.busy = "Waiting for wallet"
  paint()
  const hash = await wallet().writeContract({
    address: token,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, amount],
    account: state.account,
    chain: base,
  })
  state.busy = "Approving"
  paint()
  await publicClient.waitForTransactionReceipt({ hash })
}

async function trade(event) {
  event.preventDefault()
  if (ui.go.disabled && state.account && state.chainId === base.id) return
  if (!state.account) {
    await connect()
    return
  }
  if (state.chainId !== base.id) {
    try {
      await switchToBase()
      paint()
    } catch (err) {
      setStatus(plainError(err), true)
    }
    return
  }
  if (!live()) return
  const q = quote()
  if (q.empty || q.bad || q.pending || q.min === 0n) return

  const buying = state.side === "buy"
  const c = coin()
  const before = buying ? state.chirpBal : state.pintoBal
  let swapped = false
  let sold = false
  try {
    setStatus("")
    if (buying) {
      let pintoIn = q.raw
      if (viaZeroX()) {
        pintoIn = await swapLeg(c, COINS.pinto, q.raw, "Swapping to Pinto")
        swapped = true
        await loadBook()
      }
      const fresh = quoteBuy(book(), pintoIn, nowSec())
      await hookTrade(true, pintoIn, applySlippage(fresh.chirpOut, state.slipBps))
    } else {
      const pintoBefore = viaZeroX() ? await pintoBalance() : 0n
      await hookTrade(false, q.raw, q.min)
      sold = true
      // The hook paid at least q.min Pinto; the 0x leg sells what arrived (that floor on a stale read).
      if (viaZeroX()) {
        const paid = received(pintoBefore, await pintoBalance().catch(() => pintoBefore), q.min)
        await swapLeg(COINS.pinto, c, paid, `Swapping to ${c.symbol}`)
      }
    }
    await loadBook()
    await loadBalances()
    if (buying) {
      const after = state.chirpBal
      const got = before != null && after != null && after > before ? after - before : q.out
      setStatus(`You bought ${formatAmount(got, 18, 4)} Chirp.`)
    } else if (viaZeroX()) {
      setStatus(`You sold Chirp for about ${formatAmount(q.out, c.decimals, 6)} ${c.symbol}.`)
    } else {
      const after = state.pintoBal
      const got = before != null && after != null && after > before ? after - before : q.out
      setStatus(`You sold for ${formatAmount(got, 6, 6)} Pinto.`)
    }
  } catch (err) {
    const why = plainError(err)
    if (buying && swapped) {
      setStatus(`The swap worked, so your wallet now holds the Pinto. The Chirp buy did not go through: ${why} Pick Pinto and buy again.`, true)
    } else if (sold) {
      setStatus(`You sold for Pinto. The swap to ${c.symbol} did not go through, so the Pinto is in your wallet. ${why}`, true)
    } else {
      setStatus(why, true)
    }
    loadBook()
    loadBalances()
  } finally {
    state.busy = ""
    paint()
  }
}

function pintoBalance() {
  return publicClient.readContract({ address: PINTO, abi: erc20Abi, functionName: "balanceOf", args: [state.account] })
}

async function hookTrade(buying, raw, min) {
  const token = buying ? state.tokens.pinto : state.tokens.chirp
  await ensureAllowance(token, raw)
  const call = {
    address: HOOK,
    abi: hookAbi,
    functionName: buying ? "swapExactPintoForChirp" : "swapExactChirpForPinto",
    args: [raw, min, state.account],
    account: state.account,
  }
  state.busy = "Checking the price"
  paint()
  await publicClient.simulateContract(call)
  state.busy = "Waiting for wallet"
  paint()
  const hash = await wallet().writeContract({ ...call, chain: base })
  state.busy = buying ? "Buying" : "Selling"
  paint()
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== "success") throw new Error("reverted")
}

/** One 0x swap from the connected wallet. Returns what arrived: the balance rise when a read shows
 *  it, else the guaranteed floor (`minBuyAmount`, the swap reverts below it). A stale read can only
 *  under-report, so the next step never spends more than the wallet holds. */
async function swapLeg(from, to, amount, label) {
  state.busy = "Getting a swap quote"
  paint()
  const z = await zeroX("quote", {
    sell: from.address,
    buy: to.address,
    amount,
    taker: state.account,
    slipBps: state.slipBps,
  })
  if (!from.native) await ensureAllowance(from.address, amount, ALLOWANCE_HOLDER)
  const balance = () =>
    publicClient.readContract({ address: to.address, abi: erc20Abi, functionName: "balanceOf", args: [state.account] })
  const before = to.native ? 0n : await balance()
  state.busy = "Waiting for wallet"
  paint()
  const hash = await wallet().sendTransaction({
    account: state.account,
    chain: base,
    to: z.to,
    data: z.data,
    value: z.value,
    ...(z.gas ? { gas: z.gas } : {}),
  })
  state.busy = label
  paint()
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== "success") throw new Error("The swap did not go through. Nothing else was sent.")
  if (to.native) return z.minBuyAmount
  for (let i = 0; i < 4; i++) {
    const got = received(before, await balance().catch(() => before), z.minBuyAmount)
    if (got > z.minBuyAmount) return got
    await new Promise((r) => setTimeout(r, 1000))
  }
  return z.minBuyAmount
}

ui.form.addEventListener("submit", trade)
ui.connect.addEventListener("click", connect)
function changed() {
  refreshLeg()
  paint()
}
ui.buy.addEventListener("click", () => {
  state.side = "buy"
  changed()
})
ui.sell.addEventListener("click", () => {
  state.side = "sell"
  changed()
})
ui.amount.addEventListener("input", changed)
ui.slip.addEventListener("change", () => {
  state.slipBps = Number(ui.slip.value)
  changed()
})
ui.coin.addEventListener("change", () => {
  state.coin = ui.coin.value
  state.coinBal = null
  loadBalances()
  changed()
})
ui.max.addEventListener("click", () => {
  const buying = state.side === "buy"
  const have = buying ? maxSpend(coin(), balanceForSide()) : balanceForSide()
  if (have == null) return
  const dec = buying ? coin().decimals : 18
  ui.amount.value = formatAmount(have, dec, dec).replace(/,/g, "")
  changed()
})

// Wallet events are optional. Some in-app wallet browsers inject a provider whose `on` throws; uncaught here, that
// stopped the whole page bundle before the price and Field code ran, so every number stayed "—".
try {
  subscribeWallet()
} catch {}

function subscribeWallet() {
  if (!window.ethereum) return
  window.ethereum.on?.("accountsChanged", (accounts) => {
    state.account = accounts[0] && isAddress(accounts[0]) ? getAddress(accounts[0]) : null
    state.pintoBal = null
    state.chirpBal = null
    state.coinBal = null
    loadBalances()
    paint()
  })
  window.ethereum.on?.("chainChanged", (id) => {
    state.chainId = Number(id)
    paint()
  })
}

paint()
// The shared feed keeps the price fresh (live.js). loadBook() still reads chain directly, but only
// around a trade, where a 10s-old book would size the slippage floor wrong.
onLive((snap) => {
  if (!snap) {
    if (!state.book && HOOK) {
      state.readError = true
      if (!state.busy) setStatus("The price could not be read. It retries in ten seconds.", true)
    }
    return paint()
  }
  const c = snap.curve
  state.book = {
    virtualPinto: BigInt(c.virtualPinto),
    pintoInCurve: BigInt(c.pintoInCurve),
    chirpReserve: BigInt(c.chirpReserve),
    tollStart: BigInt(c.tollStart),
    opened: c.opened,
  }
  state.tokens = snap.tokens
  if (state.readError && !state.busy) setStatus("")
  state.readError = false
  paint()
})
setInterval(() => {
  if (book().tollStart !== 0n) paint()
}, 1000)
