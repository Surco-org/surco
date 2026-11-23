// Coins a buy can pay with, or a sell can pay out in. Anything but Pinto goes through 0x
// (the keyed /api/0x proxy on surcofi.com) into or out of Pinto, then through the hook.

export const PINTO = "0xb170000aeeFa790fa61D6e837d1035906839a3c8"
export const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"
// 0x's AllowanceHolder on Base. A quote that targets anything else is refused: the proxy is trusted
// for prices, not for where the user's approval goes.
export const ALLOWANCE_HOLDER = "0x0000000000001fF3684f28c67538d4D072C22734"
// ETH kept back on Max so the wallet can still pay gas for the swap, approve and buy.
export const GAS_KEEP = 300_000_000_000_000n

export const COINS = {
  pinto: { symbol: "Pinto", address: PINTO, decimals: 6 },
  eth: { symbol: "ETH", address: NATIVE, decimals: 18, native: true },
  usdc: { symbol: "USDC", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6 },
  cbeth: { symbol: "cbETH", address: "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22", decimals: 18 },
  cbbtc: { symbol: "cbBTC", address: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", decimals: 8 },
}

const same = (a, b) => typeof a === "string" && a.toLowerCase() === b.toLowerCase()

/** Turns a 0x v2 response into the fields we use. `firm` quotes must target the AllowanceHolder. */
export function parseZeroX(raw, firm) {
  if (!raw || raw.liquidityAvailable === false) throw new Error("No swap route for that coin right now.")
  const q = {
    buyAmount: BigInt(raw.buyAmount ?? "0"),
    minBuyAmount: BigInt(raw.minBuyAmount ?? "0"),
    spender: raw.issues?.allowance?.spender ?? null,
    to: raw.transaction?.to ?? null,
    data: raw.transaction?.data ?? null,
    value: BigInt(raw.transaction?.value ?? "0"),
    // 0x's own gas figure. A node's tight estimate can starve 0x's inner call (63/64 rule), seen on a fork.
    gas: raw.transaction?.gas ? BigInt(raw.transaction.gas) : null,
  }
  if (q.buyAmount === 0n || q.minBuyAmount === 0n) throw new Error("The swap quote came back empty.")
  if (firm) {
    if (!same(q.to, ALLOWANCE_HOLDER) || !q.data) throw new Error("The swap quote looked wrong, so it was refused.")
    if (q.spender && !same(q.spender, ALLOWANCE_HOLDER)) throw new Error("The swap quote looked wrong, so it was refused.")
  }
  return q
}

/** kind "price" is a cheap preview; "quote" is firm and needs a taker. */
export async function zeroX(kind, { sell, buy, amount, taker, slipBps }, doFetch = fetch) {
  const qs = new URLSearchParams({
    chainId: "8453",
    sellToken: sell,
    buyToken: buy,
    sellAmount: amount.toString(),
    slippageBps: String(slipBps),
  })
  if (taker) qs.set("taker", taker)
  const res = await doFetch(`/api/0x/${kind}?${qs}`)
  if (res.status === 429) throw new Error("Too many quotes. Wait a moment.")
  if (!res.ok) throw new Error("The swap quote failed. Try again.")
  return parseZeroX(await res.json(), kind === "quote")
}

/** Max for a coin: all of it, except ETH keeps GAS_KEEP for gas. */
export function maxSpend(coin, balance) {
  if (balance == null) return null
  if (!coin.native) return balance
  return balance > GAS_KEEP ? balance - GAS_KEEP : 0n
}

/** What a swap delivered: the balance rise if a read shows it, else the floor the swap guaranteed.
 *  A stale read (load-balanced RPC behind the block) shows no rise, so it falls back to the floor;
 *  a read can never show more than arrived. */
export function received(before, after, floor) {
  const rise = after > before ? after - before : 0n
  return rise >= floor ? rise : floor
}
