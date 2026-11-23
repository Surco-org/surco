// Shared wallet, Base-network switch, exact-amount approval, and simulate-before-send helpers
// for the launcher pages. Guards against mobile/Brave injected-provider quirks.
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  custom,
  erc20Abi,
  getAddress,
  http,
} from "viem"
import { base } from "viem/chains"
import { BASE_CHAIN_ID, PERMIT2, PERMIT2_ABI, READ_RPC_URL } from "./launcher-config.js"
import { shortAddr } from "./launcher-core.js"

export const publicClient = createPublicClient({ chain: base, transport: http(READ_RPC_URL) })

const walletState = {
  account: null,
  chainId: null,
  listeners: new Set(),
}

function notify() {
  for (const fn of walletState.listeners) {
    try {
      fn({ account: walletState.account, chainId: walletState.chainId })
    } catch {}
  }
}

export function getWallet() {
  return { account: walletState.account, chainId: walletState.chainId }
}

export function onWallet(fn) {
  walletState.listeners.add(fn)
  fn({ account: walletState.account, chainId: walletState.chainId })
  return () => walletState.listeners.delete(fn)
}

function getProvider() {
  return typeof window !== "undefined" ? window.ethereum ?? null : null
}

export function getWalletClient() {
  const eth = getProvider()
  if (!eth || !walletState.account) throw new Error("Connect a wallet first.")
  return createWalletClient({ chain: base, transport: custom(eth), account: walletState.account })
}

export async function connectWallet() {
  const eth = getProvider()
  if (!eth) throw new Error("No wallet detected. Open in a wallet browser or install MetaMask / Coinbase Wallet.")
  const accounts = await eth.request({ method: "eth_requestAccounts" })
  if (!accounts?.length) throw new Error("Wallet did not return an account.")
  walletState.account = getAddress(accounts[0])
  const cid = await eth.request({ method: "eth_chainId" })
  walletState.chainId = Number(cid)
  notify()
  return walletState.account
}

export async function ensureBaseChain() {
  const eth = getProvider()
  if (!eth) throw new Error("No wallet detected.")
  const cid = Number(await eth.request({ method: "eth_chainId" }))
  walletState.chainId = cid
  if (cid === BASE_CHAIN_ID) return
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x2105" }] })
  } catch (e) {
    if (e?.code === 4902) {
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: "0x2105",
            chainName: "Base",
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            rpcUrls: ["https://mainnet.base.org"],
            blockExplorerUrls: ["https://basescan.org"],
          },
        ],
      })
    } else {
      throw new Error("Please switch your wallet to Base (chain 8453).")
    }
  }
  walletState.chainId = BASE_CHAIN_ID
  notify()
}

/** Wires the #connect button and safely subscribes to provider account/chain events. */
export function initWalletButton(btnSelector = "#connect") {
  const btn = document.querySelector(btnSelector)
  const paint = ({ account }) => {
    if (!btn) return
    btn.textContent = account ? shortAddr(account) : "Connect wallet"
  }
  onWallet(paint)

  if (btn) {
    btn.addEventListener("click", async () => {
      try {
        await connectWallet()
      } catch (e) {
        // Let page status handle detailed errors; fallback alert only if none
        btn.title = e?.message || "Wallet connection failed"
      }
    })
  }

  const eth = getProvider()
  if (!eth) return
  eth
    .request({ method: "eth_accounts" })
    .then(async (accs) => {
      if (accs?.length) {
        walletState.account = getAddress(accs[0])
        walletState.chainId = Number(await eth.request({ method: "eth_chainId" }))
        notify()
      }
    })
    .catch(() => {})

  try {
    eth.on?.("accountsChanged", (accs) => {
      walletState.account = accs?.length ? getAddress(accs[0]) : null
      notify()
    })
    eth.on?.("chainChanged", (cid) => {
      walletState.chainId = Number(cid)
      notify()
    })
  } catch {
    // Guard against in-app wallet providers whose ethereum.on throws (Brave/mobile)
  }
}

/** Friendly human error text from viem / wallet errors. */
export function friendlyError(err, customMap = {}) {
  if (!err) return "Something went wrong."
  if (err.code === 4001 || /user rejected|rejected the request/i.test(err.shortMessage || err.message || "")) {
    return "Transaction cancelled in wallet."
  }
  if (err instanceof BaseError) {
    const rev = err.walk((e) => e instanceof ContractFunctionRevertedError)
    if (rev instanceof ContractFunctionRevertedError) {
      const name = rev.data?.errorName
      if (name && customMap[name]) return customMap[name]
      if (name) return `Contract reverted: ${name}`
    }
    if (err.shortMessage) return err.shortMessage
  }
  return err.message || "Transaction failed."
}

/** Ensures exact-amount ERC-20 allowance for `spender`. */
export async function ensureErc20Approval(token, spender, amount, onStep) {
  const { account } = getWallet()
  const wc = getWalletClient()
  const cur = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account, spender],
  })
  if (cur >= amount) return
  onStep?.("Approve exact amount in wallet…")
  const call = {
    account,
    address: token,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, amount],
  }
  await publicClient.simulateContract(call)
  const hash = await wc.writeContract({ ...call, chain: base })
  onStep?.("Waiting for approval…")
  await publicClient.waitForTransactionReceipt({ hash })
}

/** Ensures exact-amount ERC-20 -> Permit2 AND Permit2 -> spender allowance (24h expiry). */
export async function ensurePermit2Approval(token, spender, amount, onStep) {
  const { account } = getWallet()
  const wc = getWalletClient()
  await ensureErc20Approval(token, PERMIT2, amount, onStep)
  const [allowed, exp] = await publicClient.readContract({
    address: PERMIT2,
    abi: PERMIT2_ABI,
    functionName: "allowance",
    args: [account, token, spender],
  })
  const nowSec = Math.floor(Date.now() / 1000)
  if (BigInt(allowed) >= amount && Number(exp) > nowSec + 120) return
  const expiry = nowSec + 86_400 // 24 hours
  onStep?.("Approve Permit2 allowance in wallet…")
  const call = {
    account,
    address: PERMIT2,
    abi: PERMIT2_ABI,
    functionName: "approve",
    args: [token, spender, amount, expiry],
  }
  await publicClient.simulateContract(call)
  const hash = await wc.writeContract({ ...call, chain: base })
  onStep?.("Waiting for Permit2 approval…")
  await publicClient.waitForTransactionReceipt({ hash })
}

/** Simulates a contract write on Base, then delegates gas/fee sizing to the connected wallet (EIP-7702 / Base App safe). */
export async function sendSimulatedWrite(params, onStep) {
  await ensureBaseChain()
  const { account } = getWallet()
  const wc = getWalletClient()
  const call = { ...params, account }
  if (call.value === 0n) delete call.value
  onStep?.("Checking transaction…")
  await publicClient.simulateContract(call)
  onStep?.("Confirm in wallet…")
  const hash = await wc.writeContract({ ...call, chain: base })
  onStep?.("Waiting for Base confirmation…")
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== "success") throw new Error("Transaction reverted on Base.")
  return { hash, receipt }
}
