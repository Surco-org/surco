// The Field section: what the book holds in Pinto's silo and field, from the shared /api/chirp feed
// (live.js), plus the three upkeep calls anyone may make (nobody is paid to make them, so the page offers them).
import { BaseError, ContractFunctionRevertedError, createPublicClient, createWalletClient, custom, getAddress, http, parseAbi } from "viem"
import { base } from "viem/chains"
import { formatAmount } from "./quote.js"
import { onLive, refreshLive } from "./live.js"

const SUPPLY = 1_000_000_000n * 10n ** 18n
const client = createPublicClient({ chain: base, transport: http("https://base.publicnode.com") })

const bookAbi = parseAbi([
  "function claim()",
  "function sow(uint256 amount, uint256 minTemperature)",
  "function harvest(uint256 start)",
  "error NotOpen()",
  "error AbovePeg()",
  "error SowAmount()",
  "error NotEnoughSoil()",
  "error BelowMaxTemperature()",
  "error ZeroPods()",
  "error PintoMissing()",
  "error ChirpMissing()",
])

const REVERT = {
  AbovePeg: "Pinto is above its peg, so the field is closed.",
  NotEnoughSoil: "The field has less soil than that now.",
  BelowMaxTemperature: "The temperature is below its max right now. Sowing waits for the max.",
  SowAmount: "There is nothing to sow.",
  ZeroPods: "That sow would earn no pods.",
}

const $ = (id) => document.querySelector(id)
const set = (id, text) => {
  const el = $(id)
  if (el) el.textContent = text
}
const pinto = (raw) => `${formatAmount(raw, 6, 2)} Pinto`
const pct = (t) => `${formatAmount(t, 6, 1)}%`

let book = null
let s = null // last feed reading
let busy = false

// The feed sends raw values as strings; turn them back into bigints and work out the ripe plots.
function fieldState(f) {
  const n = (v) => BigInt(v)
  let pods = 0n
  let ripePods = 0n
  let firstRipe = -1
  f.plots.forEach(([id, index, count], i) => {
    pods += n(count)
    if (n(index) + n(count) <= n(f.lines[id])) {
      ripePods += n(count)
      if (firstRipe < 0) firstRipe = i
    }
  })
  return {
    silo: n(f.silo), pile: n(f.pile), stalk: n(f.stalk), grown: n(f.grown), earned: n(f.earned),
    soil: n(f.soil), temp: n(f.temp), maxTemp: n(f.maxTemp), below: f.below,
    burned: SUPPLY - n(f.supply), plots: f.plots.length, pods, ripePods, firstRipe,
  }
}

function sowState() {
  if (s.pile === 0n) return { ok: false, why: "Nothing waiting to sow." }
  if (!s.below) return { ok: false, why: "Waits for Pinto to dip below its peg." }
  if (s.soil === 0n) return { ok: false, why: "No soil in the field this season." }
  if (s.temp < s.maxTemp) return { ok: false, why: `Waits for max temperature (now ${pct(s.temp)} of ${pct(s.maxTemp)}).` }
  return { ok: true, amount: s.pile < s.soil ? s.pile : s.soil }
}

function paint() {
  if (!s) return
  set("#f-silo", pinto(s.silo))
  set("#f-stalk", formatAmount(s.stalk, 16, 2))
  set("#f-grown", formatAmount(s.grown, 16, 4))
  set("#f-yield", pinto(s.earned))
  set("#f-burned", `${formatAmount(s.burned, 18, 2)} Chirp`)
  set("#f-pile", pinto(s.pile))
  set("#f-plots", s.plots === 0 ? "No plots yet" : `${s.plots} plots, ${formatAmount(s.pods, 6, 2)} pods`)
  set("#f-ripe", `${formatAmount(s.ripePods, 6, 2)} pods`)
  const sow = sowState()
  set("#f-sow", sow.ok ? `Open: ${pinto(s.soil)} of soil at ${pct(s.temp)}` : sow.why)

  $("#do-claim").disabled = busy || s.earned === 0n
  $("#do-sow").disabled = busy || !sow.ok
  $("#do-harvest").disabled = busy || s.firstRipe < 0
}

function plain(err) {
  if (err instanceof BaseError) {
    const rev = err.walk((e) => e instanceof ContractFunctionRevertedError)
    if (rev instanceof ContractFunctionRevertedError) return REVERT[rev.data?.errorName] ?? "The call would fail right now."
    if (err.walk((e) => e.name === "UserRejectedRequestError")) return "You closed the wallet."
  }
  return "That did not go through."
}

async function act(functionName, args, done) {
  const status = $("#field-status")
  if (!window.ethereum) {
    status.textContent = "Open this page in a browser with a wallet."
    return
  }
  busy = true
  paint()
  try {
    const wallet = createWalletClient({ chain: base, transport: custom(window.ethereum) })
    const [raw] = await wallet.requestAddresses()
    const account = getAddress(raw)
    if ((await wallet.getChainId()) !== base.id) await wallet.switchChain({ id: base.id })
    status.textContent = "Checking…"
    const { request } = await client.simulateContract({ address: book, abi: bookAbi, functionName, args, account })
    status.textContent = "Waiting for wallet…"
    const hash = await wallet.writeContract({ ...request, chain: base })
    status.textContent = "Sending…"
    const r = await client.waitForTransactionReceipt({ hash })
    if (r.status !== "success") throw new Error("reverted")
    status.textContent = done
  } catch (err) {
    status.textContent = plain(err)
  } finally {
    busy = false
    refreshLive()
  }
}

$("#do-claim")?.addEventListener("click", () => act("claim", [], "Claimed. The yield bought Chirp and burned it."))
$("#do-sow")?.addEventListener("click", () => {
  const sow = sowState() // at most 10s old; the simulate refuses a sow the field can no longer take
  if (sow.ok) act("sow", [sow.amount, s.maxTemp], "Sown. The new plot is in the field.")
})
$("#do-harvest")?.addEventListener("click", () => act("harvest", [BigInt(s.firstRipe)], "Harvested. The Pinto bought Chirp and burned it."))

onLive((snap) => {
  // A failed poll keeps the last reading on screen; only an empty section says so.
  if (!snap) return s || busy ? undefined : set("#field-status", "The field could not be read. It retries in ten seconds.")
  book = snap.book
  s = fieldState(snap.field)
  if ($("#field-status").textContent.startsWith("The field could not")) set("#field-status", "")
  paint()
})
