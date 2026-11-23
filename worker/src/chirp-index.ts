// Chirp activity index: decodes the book's and the token's logs into rows for D1 (see chirp.ts, which runs it on
// the claimed 10s refresh). The book always records the HOOK as payer (ChirpHook calls book.buy/sell with
// address(this)), so a buyer is Bought.recipient and a seller is the `from` of the same-tx Chirp transfer to the hook.
import { decodeEventLog, parseAbi, type Hex } from "viem";
import type { D1Like } from "./chirp";

export const BOOK = "0x10b919a89a5abfecebd805836da174f02b023756";
export const HOOK = "0x91b48a16f0d78ca7eae464865f9bec753cb72ae8";
export const CHIRP = "0x4d2d8c1e1c8239ca56db7612c9efe5d6a1a2ea13";
export const LAUNCH_BLOCK = 58_889_183;

const abi = parseAbi([
  "event Bought(address indexed payer, address indexed recipient, uint256 pintoIn, uint256 chirpOut)",
  "event Sold(address indexed payer, uint256 chirpIn, uint256 pintoOut)",
  "event Sowed(uint256 indexed fieldId, uint256 index, uint256 pintoAmount, uint256 pods)",
  "event Harvested(uint256 beans)",
  "event Transfer(address indexed from, address indexed to, uint256 amount)",
]);

export type RawLog = {
  address: string;
  topics: string[];
  data: string;
  blockNumber: string;
  blockTimestamp: string;
  transactionHash: string;
  logIndex: string;
  removed?: boolean;
};
export type EventRow = {
  block: number;
  log: number;
  tx: string;
  t: number;
  kind: "buy" | "sell" | "buyback" | "sow" | "harvest";
  who: string | null;
  pinto: string;
  chirp: string;
  extra: string | null;
};
export type TransferRow = { block: number; log: number; from: string; to: string; amount: bigint };

export function decodeLogs(logs: RawLog[]): { events: EventRow[]; transfers: TransferRow[] } {
  const events: EventRow[] = [];
  const transfers: TransferRow[] = [];
  const sellerByTx = new Map<string, string>();
  const decoded = [];
  for (const l of logs) {
    const addr = l.address.toLowerCase();
    if (l.removed || (addr !== BOOK && addr !== CHIRP)) continue;
    let ev;
    try {
      ev = decodeEventLog({ abi, topics: l.topics as [Hex, ...Hex[]], data: l.data as Hex });
    } catch {
      continue; // an event this index does not know
    }
    // A missing timestamp would write NaN and fail every retry of the batch: refuse the read, loudly, instead.
    if (!l.blockTimestamp) throw new Error(`log without blockTimestamp (tx ${l.transactionHash}): the RPC must return it`);
    const at = { block: Number(l.blockNumber), log: Number(l.logIndex), tx: l.transactionHash, t: Number(l.blockTimestamp) };
    if (ev.eventName === "Transfer" && addr === CHIRP) {
      const from = ev.args.from.toLowerCase(), to = ev.args.to.toLowerCase();
      transfers.push({ block: at.block, log: at.log, from, to, amount: ev.args.amount });
      if (to === HOOK) sellerByTx.set(l.transactionHash, from);
    } else if (addr === BOOK) decoded.push({ at, ev });
  }
  for (const { at, ev } of decoded) {
    const row = { ...at, who: null as string | null, chirp: "0", extra: null as string | null };
    if (ev.eventName === "Bought") {
      const buyback = ev.args.payer.toLowerCase() === BOOK;
      events.push({ ...row, kind: buyback ? "buyback" : "buy", who: buyback ? null : ev.args.recipient.toLowerCase(), pinto: String(ev.args.pintoIn), chirp: String(ev.args.chirpOut) });
    } else if (ev.eventName === "Sold") {
      events.push({ ...row, kind: "sell", who: sellerByTx.get(at.tx) ?? null, pinto: String(ev.args.pintoOut), chirp: String(ev.args.chirpIn) });
    } else if (ev.eventName === "Sowed") {
      const extra = JSON.stringify({ fieldId: String(ev.args.fieldId), index: String(ev.args.index), pods: String(ev.args.pods) });
      events.push({ ...row, kind: "sow", pinto: String(ev.args.pintoAmount), extra });
    } else if (ev.eventName === "Harvested") {
      events.push({ ...row, kind: "harvest", pinto: String(ev.args.beans) });
    }
  }
  return { events, transfers };
}

// ---- D1 side ------------------------------------------------------------------------------------------------

export const SPAN = 200_000; // blocks per refresh: a long idle gap catches up over a few refreshes
export const SETTLE = 10; // stay ~2s behind head so a shallow reorg never writes a row that later vanishes
export const MAX_ROWS = 30; // events + holder writes per pass: Workers Free allows ~50 D1 queries per invocation
export const IDLE_READ_MS = 300_000; // read logs at least every 5 min even when the book did not move
const ZERO = "0x0000000000000000000000000000000000000000";

export type GetLogs = (from: number, to: number) => Promise<RawLog[]>;
export type Usage = {
  trades24h: number; trades7d: number; tradesAll: number; wallets: number; volume24h: number; volumeAll: number; holders: number;
};

/** Reads [cursor+1, min(cursor+SPAN, head-SETTLE)] and writes events, holder balances, the range and the cursor in
 *  ONE batch (a D1 transaction). The `ranges` primary key makes a second writer from the same cursor roll back, so a
 *  range is applied exactly once. A busy range is cut at a block boundary to stay under MAX_ROWS writes; the cursor
 *  then stops at that block and the next refresh carries on. */
export async function indexChirp(db: D1Like, getLogs: GetLogs, head: number) {
  const cur = (await db.prepare("SELECT t FROM live WHERE k = 'cursor'").first<{ t: number }>())!.t;
  let to = Math.min(cur + SPAN, head - SETTLE);
  if (to <= cur) return { from: cur + 1, to: cur, added: 0 };
  const logs = (await getLogs(cur + 1, to)).slice().sort((a, b) => Number(a.blockNumber) - Number(b.blockNumber) || Number(a.logIndex) - Number(b.logIndex));

  // Take whole blocks while the writes fit (always at least the first block).
  let take = 0;
  const touched = new Set<string>();
  let rows = 0;
  while (take < logs.length) {
    const block = logs[take].blockNumber;
    let end = take;
    const blockTouched = new Set(touched);
    let blockRows = rows;
    for (; end < logs.length && logs[end].blockNumber === block; end++) {
      const { events, transfers } = decodeLogs([logs[end]]);
      blockRows += events.length;
      for (const tr of transfers) blockTouched.add(tr.from), blockTouched.add(tr.to);
    }
    if (take > 0 && blockRows + blockTouched.size > MAX_ROWS) {
      to = Number(block) - 1;
      break;
    }
    take = end;
    rows = blockRows;
    blockTouched.forEach((a) => touched.add(a));
  }
  const { events, transfers } = decodeLogs(logs.slice(0, take));

  const delta = new Map<string, bigint>();
  const add = (a: string, v: bigint) => a !== ZERO && delta.set(a, (delta.get(a) ?? 0n) + v);
  for (const tr of transfers) add(tr.from, -tr.amount), add(tr.to, tr.amount);
  const changed = [...delta].filter(([, d]) => d !== 0n);
  const now = new Map<string, bigint>();
  if (changed.length) {
    const { results } = await db.prepare("SELECT addr, bal FROM holders WHERE addr IN (SELECT value FROM json_each(?1))")
      .bind(JSON.stringify(changed.map(([a]) => a))).all<{ addr: string; bal: string }>();
    for (const r of results) now.set(r.addr, BigInt(r.bal));
  }
  const stmts = [db.prepare("INSERT INTO ranges VALUES (?1, ?2)").bind(cur + 1, to)];
  for (const e of events) {
    stmts.push(db.prepare("INSERT OR IGNORE INTO events VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)")
      .bind(e.block, e.log, e.tx, e.t, e.kind, e.who, e.pinto, e.chirp, e.extra));
  }
  for (const [addr, d] of changed) {
    const bal = (now.get(addr) ?? 0n) + d;
    stmts.push(bal > 0n
      ? db.prepare("INSERT OR REPLACE INTO holders VALUES (?1, ?2, ?3)").bind(addr, String(bal), Number(bal) / 1e18)
      : db.prepare("DELETE FROM holders WHERE addr = ?1").bind(addr));
  }
  stmts.push(db.prepare("UPDATE live SET t = ?1 WHERE k = 'cursor'").bind(to));
  await db.batch(stmts);
  return { from: cur + 1, to, added: events.length };
}

/** Trades are buys and sells; the yield buyback is neither a trade nor a wallet. Volumes in whole Pinto. */
export async function readUsage(db: D1Like, nowSec: number): Promise<Usage> {
  const r = await db.prepare(`SELECT
      SUM(t >= ?1) AS trades24h, SUM(t >= ?2) AS trades7d, COUNT(*) AS tradesAll, COUNT(DISTINCT who) AS wallets,
      COALESCE(SUM(CASE WHEN t >= ?1 THEN CAST(pinto AS REAL) END), 0) / 1e6 AS volume24h,
      COALESCE(SUM(CAST(pinto AS REAL)), 0) / 1e6 AS volumeAll,
      (SELECT COUNT(*) FROM holders) AS holders
    FROM events WHERE kind IN ('buy', 'sell')`).bind(nowSec - 86_400, nowSec - 7 * 86_400).first<Usage>();
  const n = (v: unknown) => Number(v ?? 0);
  return {
    trades24h: n(r?.trades24h), trades7d: n(r?.trades7d), tradesAll: n(r?.tradesAll), wallets: n(r?.wallets),
    volume24h: n(r?.volume24h), volumeAll: n(r?.volumeAll), holders: n(r?.holders),
  };
}

/** Read logs when the book's state moved (every buy, sell, buyback, sow and harvest changes it), or when the last
 *  read is 5 min old (plain wallet-to-wallet transfers leave the book alone), or the first time. */
export function shouldIndex(prev: Record<string, string> | undefined, next: Record<string, string>, lastReadMs: number, nowMs: number) {
  if (!prev || nowMs - lastReadMs >= IDLE_READ_MS) return true;
  return Object.keys(next).some((k) => prev[k] !== next[k]);
}

/** The refresh's whole indexing step. State in the cursor row's body: {readMs, book} — book is the snapshot keys
 *  of the last read, or null while catching up (forces a read every refresh until the cursor reaches head).
 *  A failed read still records readMs + the current keys, so a dead or capped RPC is retried on the next book move
 *  or after 5 min — never every 10s. Returns usage for /api/chirp. */
export async function indexIfDue(
  db: D1Like, keys: Record<string, string>, nowMs: number, head: () => Promise<number>, getLogs: GetLogs,
): Promise<Usage> {
  const row = await db.prepare("SELECT body FROM live WHERE k = 'cursor'").first<{ body: string }>();
  const st = JSON.parse(row?.body || "{}") as { readMs?: number; book?: Record<string, string> | null };
  if (shouldIndex(st.book ?? undefined, keys, st.readMs ?? 0, nowMs)) {
    const save = (book: Record<string, string> | null) =>
      db.prepare("UPDATE live SET body = ?1 WHERE k = 'cursor'").bind(JSON.stringify({ readMs: nowMs, book })).run();
    try {
      const h = await head();
      const r = await indexChirp(db, getLogs, h);
      await save(r.to >= h - SETTLE ? keys : null);
    } catch (e) {
      await save(keys);
      throw e;
    }
  }
  return readUsage(db, Math.floor(nowMs / 1000));
}
