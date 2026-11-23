// GET /api/chirp/activity?before=<block>-<log> and GET /api/chirp/holders — D1 reads only (chirp-index.ts writes).
import type { D1Like } from "./chirp";

const PAGE = 50;
const TOP = 100;
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "public, max-age=10" } });

export async function handleActivity(db: D1Like, url: URL) {
  const before = url.searchParams.get("before");
  const cols = "block, log, tx, t, kind, who, pinto, chirp, extra";
  if (before === null) {
    const { results } = await db.prepare(`SELECT ${cols} FROM events ORDER BY block DESC, log DESC LIMIT ?1`).bind(PAGE).all();
    return json({ rows: results });
  }
  const m = /^(\d+)-(\d+)$/.exec(before);
  if (!m) return json({ error: "before must be <block>-<log>" }, 400);
  const { results } = await db.prepare(
    `SELECT ${cols} FROM events WHERE block < ?1 OR (block = ?1 AND log < ?2) ORDER BY block DESC, log DESC LIMIT ?3`,
  ).bind(Number(m[1]), Number(m[2]), PAGE).all();
  return json({ rows: results });
}

export async function handleHolders(db: D1Like) {
  const count = (await db.prepare("SELECT COUNT(*) AS n FROM holders").first<{ n: number }>())?.n ?? 0;
  const { results } = await db.prepare("SELECT addr, bal FROM holders ORDER BY sort DESC LIMIT ?1").bind(TOP).all();
  return json({ count, rows: results });
}
