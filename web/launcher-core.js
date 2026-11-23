// Pure, unit-tested logic for the Surco Launcher pages:
// - Safe imageURI sanitization & deterministic monogram fallback
// - Fee split, sniper toll, first-buy estimate, and Redeem payout math
// - Universal Router v4 + V4Quoter PoolKey / calldata encoding
// - Number, address, and time formatters
import { encodeAbiParameters, encodeFunctionData, getAddress, isAddress, keccak256, parseAbiParameters } from "viem"
import {
  HOOK,
  LP_FEE,
  PLATFORM_BPS,
  REDEEM_FEE_BPS,
  START_FDV_WETH,
  SUPPLY_WEI,
  TICK_SPACING,
  TOLL_START_BPS,
  TOLL_WINDOW,
  UNIVERSAL_ROUTER_ABI,
  WETH,
} from "./launcher-config.js"

// Universal Router Commands.sol & v4-periphery Actions.sol constants.
export const CMD_WRAP_ETH = "0b"
export const CMD_UNWRAP_WETH = "0c"
export const CMD_V4_SWAP = "10"

export const ACT_SWAP_EXACT_IN_SINGLE = "06"
export const ACT_SETTLE = "0b"
export const ACT_SETTLE_ALL = "0c"
export const ACT_TAKE = "0e"
export const ACT_TAKE_ALL = "0f"

export const ADDRESS_MSG_SENDER = "0x0000000000000000000000000000000000000001"
export const ADDRESS_THIS = "0x0000000000000000000000000000000000000002"
export const OPEN_DELTA = 0n

const IPFS_GATEWAY = "https://dweb.link/ipfs/"
const CID_PATH_RE = /^[a-zA-Z0-9]+(?:\/[a-zA-Z0-9._-]+)*$/

/** Sanitizes an external https:// URL (website / X link). Normalizes bare domains (e.g. surcofi.com -> https://surcofi.com/). Rejects javascript:, data:, http:, whitespace. */
export function sanitizeExternalUrl(raw) {
  if (typeof raw !== "string") return ""
  let s = raw.trim()
  if (!s || s.length > 256) return ""
  if (/[\u0000-\u001f\u007f\s]/.test(s)) return ""
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s) && s.includes(".")) {
    s = `https://${s}`
  }
  try {
    const u = new URL(s)
    if (u.protocol !== "https:") return ""
    return u.toString()
  } catch {
    return ""
  }
}

/**
 * Sanitizes an on-chain or user-pasted imageURI.
 * Permits only https:// URLs or ipfs://<cid>[/path] (rewritten to a fixed HTTPS gateway).
 * Rejects javascript:, data:, http:, whitespace/control chars, or malformed URLs.
 */
export function sanitizeImageUri(raw) {
  if (typeof raw !== "string") return ""
  const s = raw.trim()
  if (!s || s.length > 512) return ""
  if (/[\u0000-\u001f\u007f\s]/.test(s)) return ""
  if (s.toLowerCase().startsWith("ipfs://")) {
    const rest = s.slice(7).replace(/^ipfs\//i, "")
    if (!CID_PATH_RE.test(rest)) return ""
    return `${IPFS_GATEWAY}${rest}`
  }
  try {
    const u = new URL(s)
    if (u.protocol !== "https:") return ""
    return u.toString()
  } catch {
    return ""
  }
}

/** Deterministic monogram text & HSL palette derived from coin address/symbol. */
export function monogramInfo(address, symbol) {
  const cleanSym = String(symbol || "").replace(/[^a-zA-Z0-9]/g, "").toUpperCase()
  const label = cleanSym.slice(0, 3) || "?"
  const seed = String(address || symbol || "0").toLowerCase()
  let h = 2166136261
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  const hue = Math.abs(h) % 360
  return {
    label,
    bg: `hsl(${hue} 42% 86%)`,
    fg: `hsl(${hue} 48% 24%)`,
  }
}

/** Exact mirror of FeeMath.tollBps(nowSec, launchedAt, feeBps). */
export function tollBpsAt(nowSec, launchedAt, feeBps) {
  if (!launchedAt || nowSec < launchedAt) return feeBps
  const dt = nowSec - launchedAt
  if (dt >= TOLL_WINDOW) return feeBps
  const drop = Math.floor(((TOLL_START_BPS - feeBps) * dt) / TOLL_WINDOW)
  return TOLL_START_BPS - drop
}

/** Splits the trade fee into platform (fixed 20%), creator (0–20%), and Pinto Silo (remainder). */
export function feeSplitBps(creatorBps) {
  const c = Math.max(0, Math.min(2000, Math.round(Number(creatorBps) || 0)))
  return {
    platformBps: PLATFORM_BPS,
    creatorBps: c,
    pintoBps: 10_000 - PLATFORM_BPS - c,
  }
}

/** Estimates tokens bought on a creator's first buy at launch (single-sided 10 WETH FDV curve). */
export function estimateFirstBuyCoins(ethWei, feeBps) {
  if (ethWei <= 0n) return 0n
  const net = (ethWei * BigInt(10_000 - feeBps)) / 10_000n
  if (net === 0n) return 0n
  return (SUPPLY_WEI * net) / (START_FDV_WETH + net)
}

/** Exact mirror of RedeemVault.redeem() math (1% fee rounded up in the vault's favour). */
export function redeemPreview(coinAmountWei, totalSupplyWei, siloPintoRaw) {
  if (coinAmountWei <= 0n || totalSupplyWei <= 0n || siloPintoRaw <= 0n) {
    return { gross: 0n, fee: 0n, out: 0n }
  }
  const gross = (coinAmountWei * siloPintoRaw) / totalSupplyWei
  const fee = (gross * BigInt(REDEEM_FEE_BPS) + 9_999n) / 10_000n
  const out = gross > fee ? gross - fee : 0n
  return { gross, fee, out }
}

/** Exact mirror of VeChirp linear-decay & permanent max-lock weight math (amount * remainingDays / 365). */
export function veWeightAt(amountWei, remainingDays, permanent = false) {
  if (amountWei <= 0n) return 0n
  if (permanent) return amountWei
  const d = Math.max(0, Math.min(365, Math.floor(Number(remainingDays) || 0)))
  if (d <= 0) return 0n
  return (amountWei * BigInt(d)) / 365n
}

/** Builds the canonical Uniswap v4 PoolKey for any coin on this hook. */
export function buildPoolKey(coinAddr, hookAddr = HOOK) {
  const coin = getAddress(coinAddr)
  const weth = getAddress(WETH)
  const hook = getAddress(hookAddr)
  const coinIsToken0 = coin.toLowerCase() < weth.toLowerCase()
  const key = {
    currency0: coinIsToken0 ? coin : weth,
    currency1: coinIsToken0 ? weth : coin,
    fee: LP_FEE,
    tickSpacing: TICK_SPACING,
    hooks: hook,
  }
  const poolId = keccak256(
    encodeAbiParameters(parseAbiParameters("address, address, uint24, int24, address"), [
      key.currency0,
      key.currency1,
      key.fee,
      key.tickSpacing,
      key.hooks,
    ]),
  )
  return { poolKey: key, coinIsToken0, poolId }
}

const SWAP_SINGLE_PARAMS = parseAbiParameters(
  "((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, bytes hookData)",
)

function encodeSwapSingle(poolKey, zeroForOne, amountIn, amountOutMinimum) {
  return encodeAbiParameters(SWAP_SINGLE_PARAMS, [
    { poolKey, zeroForOne, amountIn, amountOutMinimum, hookData: "0x" },
  ])
}

/**
 * Encodes Universal Router `execute()` calldata for buying a coin with native ETH:
 * WRAP_ETH(ADDRESS_THIS, amountIn) + V4_SWAP(SWAP_EXACT_IN_SINGLE, SETTLE(WETH, amountIn, false), TAKE_ALL(coin, minOut)).
 * Zero token approvals required.
 */
export function encodeBuyWithEth(poolKey, coinIsToken0, amountIn, minOut, deadline) {
  const zeroForOne = !coinIsToken0 // WETH -> coin
  const coin = coinIsToken0 ? poolKey.currency0 : poolKey.currency1
  const wrapInput = encodeAbiParameters(parseAbiParameters("address, uint256"), [ADDRESS_THIS, amountIn])
  const actions = `0x${ACT_SWAP_EXACT_IN_SINGLE}${ACT_SETTLE}${ACT_TAKE_ALL}`
  const params = [
    encodeSwapSingle(poolKey, zeroForOne, amountIn, minOut),
    encodeAbiParameters(parseAbiParameters("address, uint256, bool"), [getAddress(WETH), amountIn, false]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [coin, minOut]),
  ]
  const v4Input = encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params])
  const commands = `0x${CMD_WRAP_ETH}${CMD_V4_SWAP}`
  return {
    commands,
    inputs: [wrapInput, v4Input],
    deadline,
    value: amountIn,
    data: encodeFunctionData({ abi: UNIVERSAL_ROUTER_ABI, functionName: "execute", args: [commands, [wrapInput, v4Input], deadline] }),
  }
}

/**
 * Encodes Universal Router `execute()` calldata for buying a coin with WETH (pulled via Permit2):
 * V4_SWAP(SWAP_EXACT_IN_SINGLE, SETTLE_ALL(WETH, amountIn), TAKE_ALL(coin, minOut)).
 */
export function encodeBuyWithWeth(poolKey, coinIsToken0, amountIn, minOut, deadline) {
  const zeroForOne = !coinIsToken0
  const coin = coinIsToken0 ? poolKey.currency0 : poolKey.currency1
  const actions = `0x${ACT_SWAP_EXACT_IN_SINGLE}${ACT_SETTLE_ALL}${ACT_TAKE_ALL}`
  const params = [
    encodeSwapSingle(poolKey, zeroForOne, amountIn, minOut),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [getAddress(WETH), amountIn]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [coin, minOut]),
  ]
  const v4Input = encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params])
  const commands = `0x${CMD_V4_SWAP}`
  return {
    commands,
    inputs: [v4Input],
    deadline,
    value: 0n,
    data: encodeFunctionData({ abi: UNIVERSAL_ROUTER_ABI, functionName: "execute", args: [commands, [v4Input], deadline] }),
  }
}

/**
 * Encodes Universal Router `execute()` calldata for selling a coin to native ETH:
 * V4_SWAP(SWAP_EXACT_IN_SINGLE, SETTLE_ALL(coin, amountIn), TAKE(WETH, ADDRESS_THIS, 0)) + UNWRAP_WETH(recipient, minOut).
 * Always passes the explicit `recipient` address (never sentinel address(1)) so unwrapped ETH lands directly in the user's wallet.
 */
export function encodeSellToEth(poolKey, coinIsToken0, amountIn, minOut, deadline, recipient) {
  const to = getAddress(recipient)
  const zeroForOne = coinIsToken0 // coin -> WETH
  const coin = coinIsToken0 ? poolKey.currency0 : poolKey.currency1
  const actions = `0x${ACT_SWAP_EXACT_IN_SINGLE}${ACT_SETTLE_ALL}${ACT_TAKE}`
  const params = [
    encodeSwapSingle(poolKey, zeroForOne, amountIn, minOut),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [coin, amountIn]),
    encodeAbiParameters(parseAbiParameters("address, address, uint256"), [getAddress(WETH), ADDRESS_THIS, OPEN_DELTA]),
  ]
  const v4Input = encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params])
  const unwrapInput = encodeAbiParameters(parseAbiParameters("address, uint256"), [to, minOut])
  const commands = `0x${CMD_V4_SWAP}${CMD_UNWRAP_WETH}`
  return {
    commands,
    inputs: [v4Input, unwrapInput],
    deadline,
    value: 0n,
    data: encodeFunctionData({ abi: UNIVERSAL_ROUTER_ABI, functionName: "execute", args: [commands, [v4Input, unwrapInput], deadline] }),
  }
}

/**
 * Encodes Universal Router `execute()` calldata for selling a coin to WETH:
 * V4_SWAP(SWAP_EXACT_IN_SINGLE, SETTLE_ALL(coin, amountIn), TAKE_ALL(WETH, minOut)).
 */
export function encodeSellToWeth(poolKey, coinIsToken0, amountIn, minOut, deadline) {
  const zeroForOne = coinIsToken0
  const coin = coinIsToken0 ? poolKey.currency0 : poolKey.currency1
  const actions = `0x${ACT_SWAP_EXACT_IN_SINGLE}${ACT_SETTLE_ALL}${ACT_TAKE_ALL}`
  const params = [
    encodeSwapSingle(poolKey, zeroForOne, amountIn, minOut),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [coin, amountIn]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [getAddress(WETH), minOut]),
  ]
  const v4Input = encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params])
  const commands = `0x${CMD_V4_SWAP}`
  return {
    commands,
    inputs: [v4Input],
    deadline,
    value: 0n,
    data: encodeFunctionData({ abi: UNIVERSAL_ROUTER_ABI, functionName: "execute", args: [commands, [v4Input], deadline] }),
  }
}

export function applySlippage(amount, slipBps) {
  if (amount <= 0n) return 0n
  const bps = Math.max(0, Math.min(9999, Math.round(Number(slipBps) || 0)))
  return (amount * BigInt(10_000 - bps)) / 10_000n
}

export function shortAddr(addr) {
  if (!addr || !isAddress(addr)) return "—"
  const a = getAddress(addr)
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

export function fmtUsd(n) {
  if (!Number.isFinite(n) || n <= 0) return "$0.00"
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`
  if (n >= 1) return `$${n.toFixed(2)}`
  if (n >= 0.01) return `$${n.toFixed(4)}`
  if (n >= 0.0001) return `$${n.toFixed(6)}`
  return `$${n.toExponential(2)}`
}

export function fmtWeth(num) {
  if (!Number.isFinite(num) || num <= 0) return "0 ETH"
  if (num >= 1) return `${num.toFixed(3)} ETH`
  if (num >= 0.001) return `${num.toFixed(4)} ETH`
  if (num >= 1e-6) return `${num.toFixed(6)} ETH`
  return `${num.toExponential(2)} ETH`
}

export function fmtWeiEth(weiStr) {
  try {
    return fmtWeth(Number(BigInt(weiStr || "0")) / 1e18)
  } catch {
    return "0 ETH"
  }
}

export function fmtPinto(num) {
  if (!Number.isFinite(num) || num <= 0) return "0 Pinto"
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(2)}M Pinto`
  if (num >= 1_000) return `${num.toLocaleString(undefined, { maximumFractionDigits: 1 })} Pinto`
  if (num >= 1) return `${num.toFixed(2)} Pinto`
  return `${num.toFixed(4)} Pinto`
}

export function fmtTokenAmount(weiStr, decimals = 18) {
  try {
    const v = Number(BigInt(weiStr || "0")) / 10 ** decimals
    if (!Number.isFinite(v) || v <= 0) return "0"
    if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(2)}M`
    if (v >= 1_000) return v.toLocaleString(undefined, { maximumFractionDigits: 1 })
    if (v >= 1) return v.toFixed(3)
    return v.toPrecision(3)
  } catch {
    return "0"
  }
}

export function relTime(unixSec, nowSec = Math.floor(Date.now() / 1000)) {
  if (!unixSec) return "—"
  const d = Math.max(0, nowSec - unixSec)
  if (d < 60) return `${d}s ago`
  if (d < 3600) return `${Math.floor(d / 60)}m ago`
  if (d < 86_400) return `${Math.floor(d / 3600)}h ago`
  return `${Math.floor(d / 86_400)}d ago`
}

/** Creates an avatar DOM node (safe <img> with monogram fallback on error, zero innerHTML). */
export function createAvatarEl(imageUri, address, symbol, sizeClass = "") {
  const wrap = document.createElement("span")
  wrap.className = `l-avatar ${sizeClass}`.trim()
  const mono = monogramInfo(address, symbol)
  wrap.style.background = mono.bg
  wrap.style.color = mono.fg

  const safeUrl = sanitizeImageUri(imageUri)
  if (safeUrl) {
    const img = document.createElement("img")
    img.src = safeUrl
    img.alt = symbol ? `${symbol} logo` : "Coin logo"
    img.loading = "lazy"
    img.referrerPolicy = "no-referrer"
    img.addEventListener("error", () => {
      img.remove()
      wrap.textContent = mono.label
    })
    wrap.appendChild(img)
  } else {
    wrap.textContent = mono.label
  }
  return wrap
}
