// Known protocol addresses labelled transparently on /chirp.
export const TEAM = "0x0db14dc82cbb0ce820f65c9796e0bc9e19ef08bf"
const KNOWN = {
  [TEAM]: { name: "Team", tag: "TEAM" },
  "0x10b919a89a5abfecebd805836da174f02b023756": { name: "Book (unsold shelf)" },
  "0x91b48a16f0d78ca7eae464865f9bec753cb72ae8": { name: "Hook" },
}

export function label(addr) {
  return KNOWN[String(addr).toLowerCase()] ?? null
}

export const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`
export const scan = (kind, v) => `https://basescan.org/${kind}/${v}`

/** "5s ago", "3m ago", "2h ago", "4d ago". */
export function ago(t, nowSec) {
  const s = Math.max(0, nowSec - t)
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

/** One table cell: a link opening Basescan in a new tab, with an optional tag chip. */
export function linkCell(text, href, tag) {
  const td = document.createElement("td")
  if (href) {
    const a = document.createElement("a")
    a.href = href
    a.target = "_blank"
    a.rel = "noopener"
    a.textContent = text
    td.append(a)
  } else td.textContent = text
  if (tag) {
    const chip = document.createElement("span")
    chip.className = "tag"
    chip.textContent = tag
    td.append(" ", chip)
  }
  return td
}

export function textCell(text, cls) {
  const td = document.createElement("td")
  td.textContent = text
  if (cls) td.className = cls
  return td
}
