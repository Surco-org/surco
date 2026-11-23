// GET /api/chirp — everything public the Chirp page shows (book, Field, Pinto/Chirp USD, price history),
// read from chain at most once per 10s for ALL visitors and kept in D1. A request that finds the stored
// copy older than 10s claims the refresh with a conditional UPDATE (only one request wins), reads the
// chain, appends the point to `points` and rewrites the served body. Everyone else gets the stored copy.
// No cron: Cloudflare cron can't go under a minute, and nobody needs updates while nobody is looking.
import { parseAbi, type Address } from "viem";

export const FRESH_MS = 10_000;
export const MAX_POINTS = 240; // chart series; `points` keeps every reading

// Immutable Chirp contracts (Base). The book's peg/chirp/pinto were checked against chain 2026-11-18.
const HOOK = "0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8";
const BOOK = "0x10b919A89a5ABfecEBd805836DA174F02B023756";
const PEG = "0x085db1415D04d6f464a36BEb3cB6CCc429ca75Ec";
const CHIRP = "0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13";
const PINTO = "0xb170000aeeFa790fa61D6e837d1035906839a3c8";
const DIAMOND = "0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const USDC_WELL = "0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1"; // Stable2: ask it, never read reserves
const PROBE = 100_000_000n; // 100 Pinto

const bookAbi = parseAbi([
  "function virtualPinto() view returns (uint256)",
  "function pintoInCurve() view returns (uint256)",
  "function chirpReserve() view returns (uint256)",
  "function tollStart() view returns (uint256)",
  "function opened() view returns (bool)",
  "function pricePintoPerChirp() view returns (uint256)",
  "function siloPinto() view returns (uint256)",
  "function sowPile() view returns (uint256)",
  "function plotCount() view returns (uint256)",
  "function plotAt(uint256 i) view returns (uint256 fieldId, uint256 index, uint256 pods)",
]);
const pintoAbi = parseAbi([
  "function balanceOfStalk(address) view returns (uint256)",
  "function balanceOfGrownStalk(address, address) view returns (uint256)",
  "function balanceOfEarnedBeans(address) view returns (uint256)",
  "function totalSoil() view returns (uint256)",
  "function temperature() view returns (uint256)",
  "function maxTemperature() view returns (uint256)",
  "function harvestableIndex(uint256) view returns (uint256)",
]);
const miscAbi = parseAbi([
  "function belowPeg() view returns (bool)",
  "function totalSupply() view returns (uint256)",
  "function getSwapOut(address, address, uint256) view returns (uint256)",
]);

type Call = { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] };
export type Multicall = (contracts: Call[]) => Promise<unknown[]>;
type Point = [number, number, number]; // [unix seconds, Pinto USD, Chirp USD]

const s = (v: unknown) => String(v);

/** Three multicalls: scalars, then the book's plots, then each plot field's harvest line. */
export async function readChirp(multicall: Multicall, nowSec: number) {
  const b = (functionName: string, args?: readonly unknown[]): Call => ({ address: BOOK, abi: bookAbi, functionName, args });
  const d = (functionName: string, args?: readonly unknown[]): Call => ({ address: DIAMOND, abi: pintoAbi, functionName, args });
  const r = await multicall([
    b("virtualPinto"), b("pintoInCurve"), b("chirpReserve"), b("tollStart"), b("opened"), b("pricePintoPerChirp"),
    b("siloPinto"), b("sowPile"), b("plotCount"),
    d("balanceOfStalk", [BOOK]), d("balanceOfGrownStalk", [BOOK, PINTO]), d("balanceOfEarnedBeans", [BOOK]),
    d("totalSoil"), d("temperature"), d("maxTemperature"),
    { address: PEG, abi: miscAbi, functionName: "belowPeg" },
    { address: CHIRP, abi: miscAbi, functionName: "totalSupply" },
    { address: USDC_WELL, abi: miscAbi, functionName: "getSwapOut", args: [PINTO, USDC, PROBE] },
  ]);
  const count = Number(r[8]);
  const plots = (count ? await multicall(Array.from({ length: count }, (_, i) => b("plotAt", [BigInt(i)]))) : []) as bigint[][];
  const ids = [...new Set(plots.map((p) => p[0]))];
  const lines = ids.length ? await multicall(ids.map((id) => d("harvestableIndex", [id]))) : [];
  const pintoUsd = Number(r[17]) / Number(PROBE);
  return {
    t: nowSec,
    hook: HOOK,
    book: BOOK,
    tokens: { chirp: CHIRP, pinto: PINTO },
    pintoUsd,
    chirpUsd: (Number(r[5]) / 1e6) * pintoUsd,
    curve: { virtualPinto: s(r[0]), pintoInCurve: s(r[1]), chirpReserve: s(r[2]), tollStart: s(r[3]), opened: r[4] as boolean },
    field: {
      silo: s(r[6]), pile: s(r[7]), stalk: s(r[9]), grown: s(r[10]), earned: s(r[11]),
      soil: s(r[12]), temp: s(r[13]), maxTemp: s(r[14]), below: r[15] as boolean, supply: s(r[16]),
      plots: plots.map((p) => p.map(s)),
      lines: Object.fromEntries(ids.map((id, i) => [s(id), s(lines[i])])),
    },
  };
}

/** Keeps the first and last point, and drops any point closer than span/max to the one kept before it,
 *  so the series stays ~max long however long the site runs, and always ends on the live reading. */
export function thin(series: Point[], max = MAX_POINTS): Point[] {
  if (series.length <= 2) return series;
  const gap = (series[series.length - 1][0] - series[0][0]) / max;
  const out = [series[0]];
  for (let i = 1; i < series.length - 1; i++) if (series[i][0] - out[out.length - 1][0] >= gap) out.push(series[i]);
  out.push(series[series.length - 1]);
  return out;
}

// Structural subset of the D1 binding, so this stays unit-testable without workers-types.
type Stmt = {
  bind(...v: unknown[]): Stmt;
  first<T>(): Promise<T | null>;
  all<T>(): Promise<{ results: T[] }>;
  run(): Promise<{ meta: { changes: number } }>;
};
export type D1Like = { prepare(sql: string): Stmt; batch(stmts: Stmt[]): Promise<unknown> };

const reply = (body: string, status = 200) =>
  new Response(body, { status, headers: { "content-type": "application/json", "cache-control": "public, max-age=5" } });

type Snap = Awaited<ReturnType<typeof readChirp>>;

/** `index` (chirp-index.ts indexIfDue, wired in index.ts) runs after a successful read and returns `usage`; its
 *  failure never fails the feed — the body keeps the previous usage. */
export async function handleChirp(
  db: D1Like,
  read: (nowSec: number) => Promise<Snap>,
  now = Date.now(),
  index?: (snap: Snap, nowMs: number) => Promise<unknown>,
) {
  const row = await db.prepare("SELECT t, body FROM live WHERE k = 'chirp'").first<{ t: number; body: string }>();
  const old = row ? (JSON.parse(row.body) as { series?: Point[]; book?: string; usage?: unknown }) : {};
  const ready = Boolean(old.book);
  if (row && ready && now - row.t < FRESH_MS) return reply(row.body);
  // Claim the refresh. Losing the race means someone else is reading right now: serve what is stored.
  const claim = await db.prepare("UPDATE live SET t = ?1 WHERE k = 'chirp' AND t = ?2").bind(now, row?.t ?? -1).run();
  if (claim.meta.changes !== 1) return ready ? reply(row!.body) : reply('{"error":"warming"}', 503);
  try {
    const nowSec = Math.floor(now / 1000);
    const snap = await read(nowSec);
    const point: Point = [nowSec, snap.pintoUsd, snap.chirpUsd];
    let usage = old.usage;
    if (index) {
      try {
        usage = await index(snap, now);
      } catch {}
    }
    const body = JSON.stringify({ ...snap, series: thin([...(old.series ?? []), point]), usage });
    await db.batch([db.prepare("UPDATE live SET body = ?1 WHERE k = 'chirp'").bind(body), ...pointWrites(db, point)]);
    return reply(body);
  } catch {
    // The claim already moved t forward, so the next try waits 10s: a dead RPC is not hammered.
    return ready ? reply(row!.body) : reply('{"error":"unavailable"}', 503);
  }
}

export const RANGES: Record<string, number | null> = { "1h": 3600, "24h": 86_400, "7d": 604_800, all: null };
// Where each range reads: 1h every reading (<= 360), 24h the 5-minute rollup (288), 7d/all the hourly one.
const SOURCE: Record<string, string> = {
  "1h": "points",
  "24h": "rollup WHERE g = 300 AND",
  "7d": "rollup WHERE g = 3600 AND",
  all: "rollup WHERE g = 3600 AND",
};

/** The reading itself plus its 5-minute and hourly rollup rows (each bucket keeps its latest reading). */
export function pointWrites(db: D1Like, p: Point) {
  return [
    db.prepare("INSERT OR REPLACE INTO points (t, pinto, chirp) VALUES (?1, ?2, ?3)").bind(...p),
    db.prepare("INSERT OR REPLACE INTO rollup VALUES (300, ?1, ?2, ?3, ?4)").bind(Math.floor(p[0] / 300), ...p),
    db.prepare("INSERT OR REPLACE INTO rollup VALUES (3600, ?1, ?2, ?3, ?4)").bind(Math.floor(p[0] / 3600), ...p),
  ];
}

/** GET /api/chirp/history?range= — readings inside the range plus the last one before it (the baseline a
 *  range's change is measured from). Only the in-range rows are thinned: an old baseline must not widen the
 *  thinning gap. `all` starts at the first reading. */
export async function handleChirpHistory(db: D1Like, url: URL, nowSec: number) {
  const range = url.searchParams.get("range") ?? "24h";
  if (!Object.hasOwn(RANGES, range)) return new Response('{"error":"range must be 1h, 24h, 7d or all"}', { status: 400, headers: { "content-type": "application/json" } });
  const secs = RANGES[range];
  const start = secs === null ? 0 : nowSec - secs;
  const src = SOURCE[range].includes("WHERE") ? SOURCE[range] : `${SOURCE[range]} WHERE`;
  type Row = { t: number; pinto: number; chirp: number };
  const [inside, before] = await Promise.all([
    db.prepare(`SELECT t, pinto, chirp FROM ${src} t >= ?1 ORDER BY t`).bind(start).all<Row>(),
    // `all`: the very first reading, so the change runs from launch, not from the end of the first hour.
    secs === null
      ? db.prepare("SELECT t, pinto, chirp FROM points ORDER BY t LIMIT 1").all<Row>()
      : db.prepare(`SELECT t, pinto, chirp FROM ${src} t < ?1 ORDER BY t DESC LIMIT 1`).bind(start).all<Row>(),
  ]);
  const pt = (r: Row): Point => [r.t, r.pinto, r.chirp];
  const points = [...before.results.map(pt), ...thin(inside.results.map(pt), 300).filter((p) => p[0] > (before.results[0]?.t ?? -1))];
  const from = secs === null ? (points[0]?.[0] ?? nowSec) : start;
  return new Response(JSON.stringify({ range, from, points }), {
    headers: { "content-type": "application/json", "cache-control": "public, max-age=10" },
  });
}
