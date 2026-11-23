// /chirp activity table and usage stats. Rows come from /api/chirp/activity (worker/src/chirp-routes.ts);
// usage rides on the shared /api/chirp feed. Every row links to its transaction on Basescan.
import { formatAmount } from "./quote.js"
import { onLive } from "./live.js"
import { ago, label, linkCell, scan, short, textCell } from "./labels.js"

const KINDS = { buy: "Buy", sell: "Sell", buyback: "Buyback", sow: "Sow", harvest: "Harvest" }

export function activityRow(e, nowSec) {
  const known = e.who ? label(e.who) : null
  return {
    time: ago(e.t, nowSec),
    kind: KINDS[e.kind] ?? e.kind,
    who: e.who ? known?.name ?? short(e.who) : "—",
    whoHref: e.who ? scan("address", e.who) : null,
    tag: known?.tag,
    pinto: formatAmount(BigInt(e.pinto), 6, 2),
    chirp: e.chirp === "0" ? "—" : formatAmount(BigInt(e.chirp), 18, 1),
    tx: scan("tx", e.tx),
  }
}

function boot() {
  const body = document.querySelector("#activity tbody")
  const more = document.querySelector("#activity-more")
  const empty = document.querySelector("#activity-empty")
  if (!body) return
  let rows = []
  let key = null

  const render = () => {
    const now = Math.floor(Date.now() / 1000)
    body.replaceChildren(...rows.map((e) => {
      const r = activityRow(e, now)
      const tr = document.createElement("tr")
      tr.className = `k-${e.kind}`
      tr.append(linkCell(r.time, r.tx), textCell(r.kind, "kind"), linkCell(r.who, r.whoHref, r.tag), textCell(r.pinto, "num"), textCell(r.chirp, "num"))
      return tr
    }))
    empty.hidden = rows.length > 0
  }
  const load = async (before) => {
    try {
      const res = await fetch(`/api/chirp/activity${before ? `?before=${before}` : ""}`)
      if (!res.ok) return
      const page = (await res.json()).rows
      rows = before ? rows.concat(page) : page
      more.hidden = page.length < 50
      render()
    } catch {}
  }
  more.addEventListener("click", () => {
    const last = rows[rows.length - 1]
    if (last) load(`${last.block}-${last.log}`)
  })

  const set = (id, v) => {
    const el = document.querySelector(id)
    if (el) el.textContent = v
  }
  onLive((snap) => {
    const u = snap?.usage
    if (!u) return
    set("#s-holders", u.holders.toLocaleString("en-US"))
    set("#s-trades", `${u.trades24h} today · ${u.tradesAll} all time`)
    set("#s-wallets", u.wallets.toLocaleString("en-US"))
    set("#s-volume", `${Math.round(u.volumeAll).toLocaleString("en-US")} Pinto`)
    // Refetch the first page only when something new was indexed.
    const k = JSON.stringify([u, snap.field?.pile, snap.field?.plots?.length])
    if (k !== key) {
      key = k
      load()
    } else render() // keep "5s ago" honest
  })
}

if (typeof document !== "undefined") boot()
