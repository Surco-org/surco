// Peg watch: posts to @chirpfi on X. A daily line on where Pinto is (and its 24h change) plus Chirp's USD price,
// and a post whenever Chirp's book sows into Pinto's Field. Every post is recorded in `xposts` BEFORE it is sent.
// No links in any text: X charges ~13x more for a post with a URL.
import type { D1Like } from "./chirp";
import { safeErr } from "./redact";
import type { XKeys } from "./xpost";

export type Live = { t: number; pintoUsd: number; chirpUsd: number };
export type EventRow = {
  block: number; log: number; tx: string; t: number;
  kind: "buy" | "sell" | "buyback" | "sow" | "harvest"; pinto: string; chirp: string; extra?: string | null;
};
export type LaunchRow = {
  coin: string;
  name: string;
  symbol: string;
  mode: number;
  fee_bps: number;
  launched_block: number;
  launched_at: number;
};
export type Mode = "off" | "dry" | "on";

// The worker's scheduled() dispatches on this exact string; wrangler.jsonc triggers.crons must list it
// (pegwatch.test.ts "cron wiring" fails if they drift).
export const PEG_WATCH_CRON = "5-59/10 * * * *";

const DAILY_HOUR_UTC = 15;
const MAX_PER_DAY = 6; // the daily always keeps the last slot
const STALE_SEC = 1800;
// Bounds D1 queries per cron run (Workers Free ~50); a longer backlog drains over the next runs.
const EVENTS_PER_TICK = 20;
// A sow older than this is history (a backfill after an RPC outage), not news: skipped, cursor moves on.
const EVENT_MAX_AGE_SEC = 1800;
// Under 1 Pinto rounds to "0 Pinto" and would spend a paid slot.
const MIN_SOW_PINTO = 1_000_000n;
// The 24h change uses the stored reading nearest to 24h ago, if one lies within this window of it.
const CHANGE_WINDOW_SEC = 3600;

const pinto = (raw: string) => ((BigInt(raw) + 500_000n) / 1_000_000n).toLocaleString("en-US");

export function dailyText(live: Live, day: { date: string; pintoChange: number | null }): string {
  const date = new Date(day.date + "T00:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  const c = day.pintoChange;
  const change = c === null ? "" : ` (${c >= 0 ? "+" : "−"}${Math.abs(c).toFixed(1)}% in 24h)`;
  return [`🌾 Pinto · ${date}`, `Pinto $${live.pintoUsd.toFixed(4)}${change}`, `Chirp $${live.chirpUsd.toPrecision(3)}`].join("\n");
}

/** States the rate this sow actually got (pods = Pinto × (1 + temperature)), not today's. Unknown → no rate. */
export function sowText(e: EventRow): string {
  let rate = "";
  try {
    const pods = Number(JSON.parse(e.extra ?? "").pods);
    const spent = Number(e.pinto);
    if (pods > 0 && spent > 0) rate = ` at ${Math.round((pods / spent - 1) * 100).toLocaleString("en-US")}%`;
  } catch {}
  return `Chirp's book sowed ${pinto(e.pinto)} Pinto into Pinto's Field${rate}.`;
}

/** Strips URLs, domain-like strings, @mentions, and control chars from untrusted launcher token names/symbols. */
export function sanitizeLabel(raw: string, maxLen: number): string {
  return String(raw ?? "")
    .replace(/https?:\/\/\S+/gi, "")
    .replace(/\bwww\.\S+/gi, "")
    .replace(/\b[a-z0-9-]+\.(?:com|xyz|io|org|net|app|gg|me|co|fi|money|eth|base|ai|dev|link|site|info|ly|to)\b/gi, "")
    .replace(/@+/g, "")
    .replace(/[\r\n\t\u0000-\u001f\u007f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLen)
    .trim();
}

/** Formats a new Surco Launcher coin announcement with zero URLs and zero @mentions. */
export function launchText(c: LaunchRow): string {
  const name = sanitizeLabel(c.name, 32) || "New coin";
  const sym = sanitizeLabel(c.symbol, 12).toUpperCase();
  const mode = c.mode === 1 ? "Burn" : "Redeem";
  const fee = c.fee_bps % 100 === 0 ? String(c.fee_bps / 100) : (c.fee_bps / 100).toFixed(2).replace(/0$/, "");
  const tag = sym ? `${name} ($${sym})` : name;
  return `🌱 New coin on Surco: ${tag}\n${mode} mode · ${fee}% fee · backed by Pinto in the Silo on Base.`;
}

// "failed:402" keeps X's HTTP status, so bad keys (401/403) and no credits (402) can be told apart.
const outcome = (r: { ok: boolean; status?: number }) => (r.ok ? "sent" : r.status ? `failed:${r.status}` : "failed");

/** One cron pass. Every post is inserted (status pending) before it is sent, so an overlapping run that
 *  reaches the same key inserts nothing and sends nothing. A failed send is marked and never retried. */
export async function pegWatchTick(
  db: D1Like,
  mode: Mode,
  send: (text: string) => Promise<{ ok: boolean; status?: number }>,
  nowMs: number,
  opts?: { launcherFactory?: string },
): Promise<{ posted: string[] }> {
  const posted: string[] = [];
  if (mode === "off") return { posted };
  const row = await db.prepare("SELECT body FROM live WHERE k = 'chirp'").first<{ body: string }>();
  if (!row) return { posted };
  const live = JSON.parse(row.body) as Live;
  const nowSec = Math.floor(nowMs / 1000);
  if (typeof live.pintoUsd !== "number" || typeof live.chirpUsd !== "number" || nowSec - live.t > STALE_SEC) return { posted };

  const wrow = await db.prepare("SELECT body FROM live WHERE k = 'xwatch'").first<{ body: string }>();
  const stored = wrow ? (JSON.parse(wrow.body) as { block?: number; log?: number; launchBlock?: number }) : {};
  const saveWatch = (w: { block: number; log: number; launchBlock?: number }) =>
    db.prepare("UPDATE live SET body = ?1 WHERE k = 'xwatch'").bind(JSON.stringify(w)).run();
  const factory = opts?.launcherFactory?.toLowerCase();

  if (stored.block === undefined) {
    // First run: remember the newest event (and newest launcher coin), post nothing (no replay of history).
    const last = await db.prepare("SELECT block, log FROM events ORDER BY block DESC, log DESC LIMIT 1").first<{ block: number; log: number }>();
    const initial: { block: number; log: number; launchBlock?: number } = { block: last?.block ?? 0, log: last?.log ?? 0 };
    if (factory) {
      const lastLaunch = await db
        .prepare("SELECT MAX(launched_block) AS b FROM launcher_coins WHERE factory = ?1")
        .bind(factory)
        .first<{ b: number | null }>();
      initial.launchBlock = lastLaunch?.b ?? 0;
    }
    await saveWatch(initial);
    return { posted };
  }

  const day = new Date(nowMs).toISOString().slice(0, 10);
  let today = (await db.prepare("SELECT COUNT(*) AS n FROM xposts WHERE day = ?1").bind(day).first<{ n: number }>())?.n ?? 0;
  const post = async (key: string, text: string) => {
    const ins = await db.prepare("INSERT OR IGNORE INTO xposts (key, t, day, text, status) VALUES (?1, ?2, ?3, ?4, 'pending')")
      .bind(key, nowSec, day, text).run();
    if (ins.meta.changes !== 1) return;
    today++;
    let status = "dry";
    if (mode === "on") {
      try {
        status = outcome(await send(text));
      } catch {
        status = "failed";
      }
    }
    await db.prepare("UPDATE xposts SET status = ?1 WHERE key = ?2").bind(status, key).run();
    posted.push(key);
  };

  const watch: { block: number; log: number; launchBlock?: number } = {
    block: stored.block,
    log: stored.log ?? 0,
    ...(stored.launchBlock !== undefined ? { launchBlock: stored.launchBlock } : {}),
  };
  const { results: fresh } = await db.prepare(
    "SELECT block, log, tx, t, kind, pinto, chirp, extra FROM events WHERE block > ?1 OR (block = ?1 AND log > ?2) ORDER BY block, log LIMIT ?3",
  ).bind(watch.block, watch.log, EVENTS_PER_TICK).all<EventRow>();
  for (const e of fresh) {
    const news = e.kind === "sow" && e.t > nowSec - EVENT_MAX_AGE_SEC && BigInt(e.pinto) >= MIN_SOW_PINTO;
    if (news && today < MAX_PER_DAY - 1) await post(`event:${e.tx}:${e.log}`, sowText(e));
    watch.block = e.block;
    watch.log = e.log;
  }

  if (factory) {
    if (watch.launchBlock === undefined) {
      // First tick after enabling launch posts: seed cursor without replaying old launches.
      const lastLaunch = await db
        .prepare("SELECT MAX(launched_block) AS b FROM launcher_coins WHERE factory = ?1")
        .bind(factory)
        .first<{ b: number | null }>();
      watch.launchBlock = lastLaunch?.b ?? 0;
    } else {
      const { results: freshLaunches } = await db
        .prepare(
          "SELECT coin, name, symbol, mode, fee_bps, launched_block, launched_at FROM launcher_coins WHERE factory = ?1 AND hidden = 0 AND launched_block > ?2 ORDER BY launched_block ASC, coin ASC LIMIT ?3",
        )
        .bind(factory, watch.launchBlock, EVENTS_PER_TICK)
        .all<LaunchRow>();
      for (const c of freshLaunches) {
        const news = c.launched_at > nowSec - EVENT_MAX_AGE_SEC;
        if (news && today < MAX_PER_DAY - 1) await post(`launch:${c.coin.toLowerCase()}`, launchText(c));
        watch.launchBlock = c.launched_block;
      }
    }
  }
  await saveWatch(watch);

  // Hand-written posts: a row inserted with status 'queued' (see HANDOFF) is sent once. The claim moves it to
  // 'pending' first, so two overlapping runs cannot both send it. Only in "on": dry leaves it queued.
  if (mode === "on") {
    const { results: queued } = await db.prepare("SELECT key, text FROM xposts WHERE status = 'queued' ORDER BY t LIMIT 2").all<{ key: string; text: string }>();
    for (const q of queued) {
      const claim = await db.prepare("UPDATE xposts SET status = 'pending' WHERE key = ?1 AND status = 'queued'").bind(q.key).run();
      if (claim.meta.changes !== 1) continue;
      let status = "failed";
      try {
        status = outcome(await send(q.text));
      } catch {}
      await db.prepare("UPDATE xposts SET status = ?1 WHERE key = ?2").bind(status, q.key).run();
      posted.push(q.key);
    }
  }

  if (new Date(nowMs).getUTCHours() >= DAILY_HOUR_UTC) {
    const ago = nowSec - 86_400;
    const then = await db.prepare("SELECT pinto FROM points WHERE t BETWEEN ?1 AND ?2 ORDER BY ABS(t - ?3) LIMIT 1")
      .bind(ago - CHANGE_WINDOW_SEC, ago + CHANGE_WINDOW_SEC, ago).first<{ pinto: number }>();
    const pintoChange = then && then.pinto > 0 ? ((live.pintoUsd - then.pinto) / then.pinto) * 100 : null;
    await post(`daily:${day}`, dailyText(live, { date: day, pintoChange }));
  }
  return { posted };
}

type XEnv = { X_POSTS?: string; X_API_KEY?: string; X_API_SECRET?: string; X_ACCESS_TOKEN?: string; X_ACCESS_SECRET?: string };

/** Unknown or missing → off. "on" without all four keys → dry, so a half-configured deploy never sends. */
export function postMode(raw: string | undefined, env: XEnv): Mode {
  if (raw !== "off" && raw !== "dry" && raw !== "on") return "off";
  if (raw === "on" && !(env.X_API_KEY && env.X_API_SECRET && env.X_ACCESS_TOKEN && env.X_ACCESS_SECRET)) return "dry";
  return raw;
}

/** The peg-watch cron run: refresh the Chirp feed (so live, points and events are current), then tick. Never
 *  throws; errors are logged with every X secret redacted. A failed refresh still ticks: the stale check guards it. */
export async function runPegWatch(
  env: XEnv & { CHIRP_DB: D1Like },
  refresh: () => Promise<unknown>,
  nowMs: number,
  post: (text: string, keys: XKeys) => Promise<{ ok: boolean; status?: number; error?: string }>,
  log: (msg: string) => void = (m) => console.error(m),
  launcherFactory?: string,
): Promise<void> {
  const secrets = [env.X_API_KEY, env.X_API_SECRET, env.X_ACCESS_TOKEN, env.X_ACCESS_SECRET];
  try {
    await refresh();
  } catch (e) {
    log("peg watch refresh skipped: " + safeErr(e, ...secrets));
  }
  try {
    const keys: XKeys = { apiKey: env.X_API_KEY ?? "", apiSecret: env.X_API_SECRET ?? "", token: env.X_ACCESS_TOKEN ?? "", tokenSecret: env.X_ACCESS_SECRET ?? "" };
    const send = async (text: string) => {
      const r = await post(text, keys);
      if (!r.ok) log(`peg watch: X refused a post (${r.status}): ` + safeErr(r.error ?? "", ...secrets));
      return r;
    };
    await pegWatchTick(env.CHIRP_DB, postMode(env.X_POSTS, env), send, nowMs, launcherFactory ? { launcherFactory } : undefined);
  } catch (e) {
    log("peg watch skipped: " + safeErr(e, ...secrets));
  }
}
