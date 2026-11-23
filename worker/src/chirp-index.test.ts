import { describe, expect, it } from "vitest";
import { encodeAbiParameters, encodeEventTopics, parseAbi, type Hex } from "viem";
import { BOOK, CHIRP, HOOK, decodeLogs, type RawLog } from "./chirp-index";

const abi = parseAbi([
  "event Bought(address indexed payer, address indexed recipient, uint256 pintoIn, uint256 chirpOut)",
  "event Sold(address indexed payer, uint256 chirpIn, uint256 pintoOut)",
  "event Sowed(uint256 indexed fieldId, uint256 index, uint256 pintoAmount, uint256 pods)",
  "event Harvested(uint256 beans)",
  "event Transfer(address indexed from, address indexed to, uint256 amount)",
]);
const u = (n: bigint) => ({ type: "uint256", value: n });
const data = (...vals: { type: string; value: bigint }[]) =>
  encodeAbiParameters(vals.map((v) => ({ type: v.type })), vals.map((v) => v.value));

let n = 0;
function log(address: string, eventName: string, args: Record<string, unknown>, d: Hex, tx = "0xt1", extra: Partial<RawLog> = {}): RawLog {
  return {
    address,
    topics: encodeEventTopics({ abi, eventName: eventName as never, args: args as never }) as string[],
    data: d,
    blockNumber: "0x10",
    blockTimestamp: "0x6900",
    transactionHash: tx,
    logIndex: `0x${(n++).toString(16)}`,
    ...extra,
  };
}

const BUYER = "0x00000000000000000000000000000000000000ab";
const SELLER = "0x00000000000000000000000000000000000000cd";

describe("decodeLogs", () => {
  it("decodes a buy: the buyer is the recipient, not the hook", () => {
    const { events } = decodeLogs([
      log(BOOK, "Bought", { payer: HOOK, recipient: BUYER }, data(u(14161841n), u(1401741274142260106380n))),
    ]);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ kind: "buy", who: BUYER, pinto: "14161841", chirp: "1401741274142260106380", block: 16, t: 0x6900, tx: "0xt1" });
  });

  it("sell wallet comes from the same-tx transfer", () => {
    const { events } = decodeLogs([
      log(CHIRP, "Transfer", { from: SELLER, to: HOOK }, data(u(700n * 10n ** 18n)), "0xs1"),
      log(BOOK, "Sold", { payer: HOOK }, data(u(700n * 10n ** 18n), u(6940014n)), "0xs1"),
      log(BOOK, "Sold", { payer: HOOK }, data(u(1n), u(1n)), "0xs2"),
    ]);
    expect(events[0]).toMatchObject({ kind: "sell", who: SELLER, chirp: "700000000000000000000", pinto: "6940014" });
    expect(events[1]).toMatchObject({ kind: "sell", who: null });
  });

  it("buyback is not a trade", () => {
    const { events } = decodeLogs([
      log(BOOK, "Bought", { payer: BOOK, recipient: "0x0000000000000000000000000000000000000000" }, data(u(5n), u(7n))),
    ]);
    expect(events[0]).toMatchObject({ kind: "buyback", who: null, pinto: "5", chirp: "7" });
  });

  it("decodes sow and harvest", () => {
    const { events } = decodeLogs([
      log(BOOK, "Sowed", { fieldId: 0n }, data(u(42n), u(1000n), u(1500n))),
      log(BOOK, "Harvested", {}, data(u(1500n))),
    ]);
    expect(events[0]).toMatchObject({ kind: "sow", who: null, pinto: "1000", chirp: "0" });
    expect(JSON.parse(events[0].extra!)).toEqual({ fieldId: "0", index: "42", pods: "1500" });
    expect(events[1]).toMatchObject({ kind: "harvest", pinto: "1500", chirp: "0", extra: null });
  });

  it("drops removed logs and other contracts; every transfer is listed", () => {
    const { events, transfers } = decodeLogs([
      log(BOOK, "Harvested", {}, data(u(1n)), "0xr", { removed: true }),
      log("0x0000000000000000000000000000000000000001", "Harvested", {}, data(u(1n))),
      log(CHIRP, "Transfer", { from: BUYER, to: SELLER }, data(u(3n))),
    ]);
    expect(events).toEqual([]);
    expect(transfers).toEqual([{ block: 16, log: expect.any(Number), from: BUYER, to: SELLER, amount: 3n }]);
  });
});

import { indexChirp, readUsage, shouldIndex, type GetLogs } from "./chirp-index";
import { testDb } from "./test-d1";

const at = (block: number, t = 1000) => ({ blockNumber: `0x${block.toString(16)}`, blockTimestamp: `0x${t.toString(16)}` });
const ZERO = "0x0000000000000000000000000000000000000000";
const FACTORY = "0x00000000000000000000000000000000000000fa";
const cursor = async (db: ReturnType<typeof testDb>) => (await db.prepare("SELECT t FROM live WHERE k = 'cursor'").first<{ t: number }>())!.t;
const holders = (db: ReturnType<typeof testDb>) => db.raw.prepare("SELECT addr, bal FROM holders ORDER BY addr").all() as { addr: string; bal: string }[];

describe("indexChirp", () => {
  it("catches up in capped steps and stops 10 blocks short of head", async () => {
    const db = testDb();
    const asked: [number, number][] = [];
    const getLogs: GetLogs = async (f, t) => (asked.push([f, t]), []);
    await indexChirp(db, getLogs, 59_400_010);
    expect(asked[0]).toEqual([58_889_183, 59_089_182]);
    expect(await cursor(db)).toBe(59_089_182);
    while ((await indexChirp(db, getLogs, 59_400_010)).to > 0 && (await cursor(db)) < 59_400_000);
    expect(await cursor(db)).toBe(59_400_000);
    const n = asked.length;
    await indexChirp(db, getLogs, 59_400_010);
    expect(asked.length).toBe(n); // nothing new to read
  });

  it("holders sum to supply minus burns; no 0x0 holder, no zero rows", async () => {
    const db = testDb();
    const S = 10n ** 27n;
    const logs = [
      log(CHIRP, "Transfer", { from: ZERO, to: FACTORY }, data(u(S)), "0xa", at(58_889_183)),
      log(CHIRP, "Transfer", { from: FACTORY, to: BOOK }, data(u(S)), "0xa", at(58_889_183)),
      log(CHIRP, "Transfer", { from: BOOK, to: BUYER }, data(u(5n * 10n ** 18n)), "0xb", at(58_889_184)),
      log(CHIRP, "Transfer", { from: BUYER, to: ZERO }, data(u(2n * 10n ** 18n)), "0xc", at(58_889_185)),
    ];
    await indexChirp(db, async () => logs, 58_889_300);
    const h = holders(db);
    expect(h.map((r) => r.addr)).toEqual([BUYER, BOOK]); // ORDER BY addr
    expect(h.reduce((a, r) => a + BigInt(r.bal), 0n)).toBe(S - 2n * 10n ** 18n);
  });

  it("a failed batch applies nothing; a healthy rerun applies the range once", async () => {
    const db = testDb();
    const logs = [
      log(CHIRP, "Transfer", { from: ZERO, to: BUYER }, data(u(9n)), "0xa", at(58_889_190)),
      log(BOOK, "Bought", { payer: HOOK, recipient: BUYER }, data(u(1n), u(9n)), "0xa", at(58_889_190)),
    ];
    const broken = { ...db, batch: async () => { throw new Error("d1 down"); } };
    await expect(indexChirp(broken, async () => logs, 58_889_300)).rejects.toThrow();
    expect(holders(db)).toEqual([]);
    expect(await cursor(db)).toBe(58_889_182);
    await indexChirp(db, async () => logs, 58_889_300);
    expect(holders(db)).toEqual([{ addr: BUYER, bal: "9" }]);
    expect(db.raw.prepare("SELECT COUNT(*) AS n FROM events").get()).toEqual({ n: 1 });
  });

  it("a getLogs failure leaves the cursor", async () => {
    const db = testDb();
    await expect(indexChirp(db, async () => { throw new Error("429"); }, 59_000_000)).rejects.toThrow();
    expect(await cursor(db)).toBe(58_889_182);
  });
});

describe("readUsage", () => {
  it("counts trades and wallets, never the buyback", async () => {
    const db = testDb();
    const now = 2_000_000;
    const ins = db.raw.prepare("INSERT INTO events VALUES (?, ?, 'x', ?, ?, ?, ?, '1', NULL)");
    ins.run(1, 0, now - 100, "buy", BUYER, "2000000");
    ins.run(1, 1, now - 200, "buy", SELLER, "1000000");
    ins.run(1, 2, now - 300, "sell", BUYER, "500000");
    ins.run(1, 3, now - 8 * 86400, "buy", BUYER, "4000000");
    ins.run(1, 4, now - 50, "buyback", null, "9000000");
    db.raw.exec(`INSERT INTO holders VALUES ('${BUYER}', '1', 0), ('${SELLER}', '1', 0)`);
    expect(await readUsage(db, now)).toEqual({
      trades24h: 3, trades7d: 3, tradesAll: 4, wallets: 2, volume24h: 3.5, volumeAll: 7.5, holders: 2,
    });
  });
});

describe("shouldIndex", () => {
  const s = { a: "1", b: "2" };
  it("reads when the book moved, when 5 min passed, or the first time", () => {
    expect(shouldIndex(undefined, s, 0, 1)).toBe(true);
    expect(shouldIndex(s, { ...s, b: "3" }, 1_000, 1_001)).toBe(true);
    expect(shouldIndex(s, s, 1_000, 1_000 + 300_000)).toBe(true);
    expect(shouldIndex(s, s, 1_000, 1_000 + 299_999)).toBe(false);
  });
});

import { indexIfDue } from "./chirp-index";

describe("indexIfDue", () => {
  const keys = { pintoInCurve: "1", chirpReserve: "2", pile: "0", plots: "0", supply: "9" };
  const state = (db: ReturnType<typeof testDb>) =>
    JSON.parse((db.raw.prepare("SELECT body FROM live WHERE k = 'cursor'").get() as { body: string }).body);

  it("indexes the first time, then skips until the book moves or 5 min pass", async () => {
    const db = testDb();
    let reads = 0;
    const getLogs: GetLogs = async () => (reads++, []);
    let h = 58_889_300;
    const head = async () => (h += 100); // the chain keeps moving
    await indexIfDue(db, keys, 1_000, head, getLogs);
    expect(reads).toBe(1);
    await indexIfDue(db, keys, 2_000, head, getLogs);
    expect(reads).toBe(1);
    await indexIfDue(db, { ...keys, pintoInCurve: "5" }, 3_000, head, getLogs);
    expect(reads).toBe(2);
    await indexIfDue(db, { ...keys, pintoInCurve: "5" }, 3_000 + 300_000, head, getLogs);
    expect(reads).toBe(3);
  });

  it("keeps reading every refresh while catching up", async () => {
    const db = testDb();
    let reads = 0;
    const getLogs: GetLogs = async () => (reads++, []);
    const head = async () => 59_400_010; // ~511k blocks behind: three spans
    for (let i = 0; i < 3; i++) await indexIfDue(db, keys, 1_000 + i, head, getLogs);
    expect(reads).toBe(3);
    expect(state(db).book).toEqual(keys);
    await indexIfDue(db, keys, 1_010, head, getLogs);
    expect(reads).toBe(3);
  });

  it("after a failed read it waits for a book move or 5 min, never retries every refresh", async () => {
    const db = testDb();
    let reads = 0;
    const getLogs: GetLogs = async () => { reads++; throw new Error("cap hit"); };
    const head = async () => 58_889_300;
    await expect(indexIfDue(db, keys, 1_000, head, getLogs)).rejects.toThrow();
    await expect(indexIfDue(db, keys, 2_000, head, getLogs)).resolves.toBeDefined();
    expect(reads).toBe(1);
  });

  it("returns usage", async () => {
    const db = testDb();
    expect((await indexIfDue(db, keys, 1_000, async () => 58_889_300, async () => [])).holders).toBe(0);
  });
});

describe("review fixes", () => {
  it("C1: two indexers from the same cursor apply the range once", async () => {
    const db = testDb();
    const logs = [log(CHIRP, "Transfer", { from: ZERO, to: BUYER }, data(u(9n)), "0xa", at(58_889_190))];
    let releaseA!: () => void, releaseB!: () => void;
    const gate = (set: (f: () => void) => void): GetLogs => () => new Promise((r) => set(() => r(logs)));
    const a = indexChirp(db, gate((f) => (releaseA = f)), 58_889_300);
    const b = indexChirp(db, gate((f) => (releaseB = f)), 58_889_300);
    await new Promise((r) => setTimeout(r, 0));
    releaseA();
    await a;
    releaseB();
    await expect(b).rejects.toThrow();
    expect(holders(db)).toEqual([{ addr: BUYER, bal: "9" }]);
  });

  it("I1: a busy range is split at block boundaries and stays under 50 queries per call", async () => {
    const db = testDb();
    let queries = 0;
    const counted = { ...db, prepare: (sql: string) => (queries++, db.prepare(sql)) };
    const logs: RawLog[] = [];
    for (let i = 0; i < 120; i++) {
      const who = `0x${(0x1000 + i).toString(16).padStart(40, "0")}`;
      logs.push(log(CHIRP, "Transfer", { from: ZERO, to: who }, data(u(1n)), `0x${i}`, at(58_889_200 + i)));
      logs.push(log(BOOK, "Bought", { payer: HOOK, recipient: who }, data(u(1n), u(1n)), `0x${i}`, at(58_889_200 + i)));
    }
    const getLogs: GetLogs = async (f, t) => logs.filter((l) => Number(l.blockNumber) >= f && Number(l.blockNumber) <= t);
    let calls = 0;
    while ((await cursor(db)) < 58_889_400 - 10) {
      queries = 0;
      await indexChirp(counted, getLogs, 58_889_400);
      expect(queries).toBeLessThanOrEqual(50);
      if (++calls > 50) throw new Error("no progress");
    }
    expect(calls).toBeGreaterThan(1);
    expect(holders(db)).toHaveLength(120);
    expect(db.raw.prepare("SELECT COUNT(*) AS n FROM events").get()).toEqual({ n: 120 });
  });

  it("I2: a log without blockTimestamp fails loudly and moves nothing", async () => {
    const db = testDb();
    const bad = { ...log(CHIRP, "Transfer", { from: ZERO, to: BUYER }, data(u(9n)), "0xa", at(58_889_190)) } as Partial<RawLog>;
    delete bad.blockTimestamp;
    await expect(indexChirp(db, async () => [bad as RawLog], 58_889_300)).rejects.toThrow(/blockTimestamp/);
    expect(await cursor(db)).toBe(58_889_182);
  });
});
