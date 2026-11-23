import { describe, expect, it } from "vitest";
import { FRESH_MS, handleChirp, thin, type D1Like } from "./chirp";

// In-memory stand-in for the two D1 tables, enough for the four statements chirp.ts runs.
function fakeDb(t: number, body: string) {
  const live = { t, body };
  const points: unknown[][] = [];
  const db: D1Like = {
    prepare(sql) {
      let v: unknown[] = [];
      const stmt = {
        bind: (...a: unknown[]) => ((v = a), stmt),
        first: async <T,>() => ({ ...live }) as T,
        all: async <T,>() => ({ results: [] as T[] }),
        run: async () => {
          if (sql.startsWith("UPDATE live SET t") && live.t === v[1]) return (live.t = v[0] as number), { meta: { changes: 1 } };
          if (sql.startsWith("UPDATE live SET body")) live.body = v[0] as string;
          if (sql.startsWith("INSERT INTO points") || sql.startsWith("INSERT OR REPLACE INTO points")) points.push(v);
          return { meta: { changes: 0 } };
        },
      };
      return stmt;
    },
    batch: async (stmts) => Promise.all(stmts.map((s) => s.run())),
  };
  return { db, live, points };
}

const snap = (t: number) => ({ t, book: "0xb", pintoUsd: 0.5, chirpUsd: 0.005 }) as never;

describe("chirp feed", () => {
  it("serves the stored copy inside 10s without reading the chain", async () => {
    const { db } = fakeDb(1_000, JSON.stringify({ book: "0xb", series: [] }));
    let reads = 0;
    const res = await handleChirp(db, async (t) => (reads++, snap(t)), 1_000 + FRESH_MS - 1);
    expect(res.status).toBe(200);
    expect(reads).toBe(0);
  });

  it("refreshes once when stale, stores the point, and a lost claim serves the old copy", async () => {
    const { db, live, points } = fakeDb(0, "{}");
    let reads = 0;
    const read = async (t: number) => (reads++, snap(t));
    const res = await handleChirp(db, read, 50_000);
    expect((await res.json()).series).toEqual([[50, 0.5, 0.005]]);
    expect(points).toEqual([[50, 0.5, 0.005]]);
    expect(live.t).toBe(50_000);
    // Another request inside the window: no chain read.
    await handleChirp(db, read, 55_000);
    expect(reads).toBe(1);
  });

  it("a failed read keeps the old body and backs off 10s", async () => {
    const old = JSON.stringify({ book: "0xb", series: [[1, 1, 1]] });
    const { db, live } = fakeDb(0, old);
    const res = await handleChirp(db, async () => { throw new Error("rpc down"); }, 99_000);
    expect(await res.text()).toBe(old);
    expect(live.t).toBe(99_000);
  });

  it("puts the index result in the body as usage", async () => {
    const { db } = fakeDb(0, "{}");
    const res = await handleChirp(db, async (t) => snap(t), 50_000, async () => ({ tradesAll: 3 }) as never);
    expect((await res.json()).usage).toEqual({ tradesAll: 3 });
  });

  it("an index failure keeps the previous usage and still serves a fresh snapshot", async () => {
    const { db } = fakeDb(0, JSON.stringify({ book: "0xb", series: [], usage: { tradesAll: 1 } }));
    const res = await handleChirp(db, async (t) => snap(t), 50_000, async () => { throw new Error("cap hit"); });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.usage).toEqual({ tradesAll: 1 });
    expect(body.t).toBe(50);
  });

  it("thin keeps the series short and ends on the live reading", () => {
    let s: [number, number, number][] = [];
    for (let t = 0; t < 100_000; t += 10) s = thin([...s, [t, 1, 1]], 50);
    expect(s.length).toBeLessThanOrEqual(52);
    expect(s[0][0]).toBe(0);
    expect(s[s.length - 1][0]).toBe(99_990);
  });
});
