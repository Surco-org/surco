// The price chart: TradingView Lightweight Charts, fed by /api/chirp/history (one range) plus the live
// /api/chirp tick. Vite bundles every page script into one chunk, so the fence is setup's try/catch here,
// load()'s own catch, and live.js calling each subscriber in its own try/catch.
import { AreaSeries, createChart, LineType } from "lightweight-charts"
import { badge, changePct, priceText, toSeries, windowRows } from "./chart-model.js"
import { onLive } from "./live.js"

const $ = (s) => document.querySelector(s)
const note = (text) => {
  const el = $("#chart-note")
  if (el) el.textContent = text
}
const SECS = { "1h": 3600, "24h": 86_400, "7d": 604_800, all: null }
const LABEL = { "1h": "1H", "24h": "24H", "7d": "7D", all: "All" }
const ARROW = { up: "▲ ", down: "▼ ", flat: "" }

function alpha(color, a) {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(color)
  return m ? `rgba(${parseInt(m[1], 16)}, ${parseInt(m[2], 16)}, ${parseInt(m[3], 16)}, ${a})` : color
}

function tick(t, type) {
  const d = new Date(t * 1000)
  if (type === 0) return String(d.getFullYear())
  if (type === 1) return d.toLocaleDateString(undefined, { month: "short" })
  if (type === 2) return d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
  return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
}

function setup() {
  const box = $("#chart")
  if (!box) return
  const priceEl = $("#chart-price")
  const changeEl = $("#chart-change")
  let range = "24h"
  let unit = "usd"
  let rows = null // [t, pintoUsd, chirpUsd][] for the current range, live ticks appended
  let dir = "flat"
  let ask = 0

  const chart = createChart(box, {
    autoSize: true,
    layout: { background: { color: "transparent" }, fontFamily: getComputedStyle(document.body).fontFamily },
    rightPriceScale: { borderVisible: false },
    timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false, tickMarkFormatter: tick },
    localization: { timeFormatter: (t) => new Date(t * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) },
    handleScale: { mouseWheel: false },
  })
  const series = chart.addSeries(AreaSeries, { lineWidth: 2, lineType: LineType.WithSteps, priceLineVisible: false })

  const paint = () => {
    const css = getComputedStyle(document.documentElement)
    const v = (k) => css.getPropertyValue(k).trim()
    const line = v(dir === "up" ? "--accent-2" : dir === "down" ? "--down" : "--ink-soft")
    chart.applyOptions({
      layout: { textColor: v("--faint") },
      grid: { vertLines: { visible: false }, horzLines: { color: alpha(v("--ink"), 0.08) } },
      crosshair: { vertLine: { labelBackgroundColor: v("--ink") }, horzLine: { labelBackgroundColor: v("--ink") } },
    })
    series.applyOptions({ lineColor: line, topColor: alpha(line, 0.28), bottomColor: alpha(line, 0.02) })
  }

  const render = (fit) => {
    if (!rows) return
    const data = toSeries(rows, unit)
    series.applyOptions({
      priceFormat: { type: "custom", minMove: 1e-9, formatter: (v) => (unit === "usd" ? priceText(v, "usd") : v.toFixed(6)) },
    })
    series.setData(data)
    if (fit) chart.timeScale().fitContent()
    if (!data.length) {
      priceEl.textContent = "—"
      changeEl.textContent = "—"
      return
    }
    const b = badge(changePct(data))
    dir = b.dir
    priceEl.textContent = priceText(data[data.length - 1].value, unit)
    changeEl.textContent = `${ARROW[b.dir]}${b.text} · ${LABEL[range]}`
    changeEl.className = `chart-change ${b.dir}`
    paint()
  }

  const load = async () => {
    const mine = ++ask
    try {
      const res = await fetch(`/api/chirp/history?range=${range}`)
      if (!res.ok) throw new Error(String(res.status))
      const body = await res.json()
      if (mine !== ask) return
      // The baseline reading sits at the range start, so the line starts there instead of days earlier.
      rows = windowRows(body.points, body.from)
      render(true)
      note("Read from Base every ten seconds while someone has the page open. A flat stretch means no reading, not no trades.")
    } catch {
      if (mine !== ask) return
      // Never show the previous range's line under the new range's label.
      rows = null
      series.setData([])
      priceEl.textContent = "—"
      changeEl.textContent = "—"
      changeEl.className = "chart-change flat"
      note("The price history could not be read. Try again in a moment.")
    }
  }

  const press = (sel, attr, value) =>
    document.querySelectorAll(sel).forEach((b) => b.setAttribute("aria-pressed", String(b.dataset[attr] === value)))
  document.querySelectorAll(".range").forEach((b) =>
    b.addEventListener("click", () => {
      range = b.dataset.range
      press(".range", "range", range)
      load()
    }),
  )
  document.querySelectorAll(".unit").forEach((b) =>
    b.addEventListener("click", () => {
      unit = b.dataset.unit
      press(".unit", "unit", unit)
      render(true)
    }),
  )

  onLive((snap) => {
    if (!snap || !rows) return
    const last = rows[rows.length - 1]
    if (last && snap.t <= last[0]) return
    rows.push([snap.t, snap.pintoUsd, snap.chirpUsd])
    // Keep the window: a 1H tab left open for hours still measures the last hour.
    if (SECS[range]) rows = windowRows(rows, snap.t - SECS[range])
    render(false)
  })
  new MutationObserver(paint).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
  paint()
  load()
}

try {
  setup()
} catch {
  note("The price chart could not start in this browser. Every other number on the page is unaffected.")
}
