// One feed for the whole page: /api/chirp, which the worker refreshes from chain at most once per 10s
// for every visitor (worker/src/chirp.ts). Polled every 10s while the tab is visible.
// Subscribers get the parsed body, or null when the feed could not be read.

const subs = []
let last = null

// Each subscriber is fenced: one module's error (say, the chart) must not stop the numbers after it.
const call = (fn, body) => {
  try {
    fn(body)
  } catch {}
}

export function onLive(fn) {
  subs.push(fn)
  if (last) call(fn, last)
}

export async function refreshLive(doFetch = fetch) {
  let body = null
  try {
    const res = await doFetch("/api/chirp")
    if (res.ok) body = await res.json()
  } catch {}
  if (body?.book) last = body
  for (const fn of subs) call(fn, body?.book ? body : null)
}

if (typeof document !== "undefined") {
  refreshLive()
  setInterval(() => document.hidden || refreshLive(), 10_000)
  document.addEventListener("visibilitychange", () => document.hidden || refreshLive())
}
