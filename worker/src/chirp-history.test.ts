import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { handleChirpHistory, pointWrites } from "./chirp";
import { testDb } from "./test-d1";

const NOW = 1_000_000;
const get = (q: string) => new URL(`https://surcofi.com/api/chirp/history${q}`);
function seed(ts: number[]) {
  const db = testDb();
  const ins = db.raw.prepare("INSERT INTO points VALUES (?, 1, ?)");
  for (const t of ts) ins.run(t, t / 1e6);
  // The migration's backfill, so seeded rows reach the rollups too.
  db.raw.exec(readFileSync(new URL("../migrations/0003_rollup.sql", import.meta.url), "utf8").split("\n").filter((l) => l.startsWith("INSERT")).join("\n"));
  return db;
}
const body = async (db: ReturnType<typeof testDb>, q: string) => (await handleChirpHistory(db, get(q), NOW)).json();

describe("chirp history", () => {
  it("1h: rows in range plus the one baseline row before it, ascending", async () => {
    const b = await body(seed([NOW - 9000, NOW - 5000, NOW - 3000, NOW - 10]), "?range=1h");
    expect(b.range).toBe("1h");
    expect(b.from).toBe(NOW - 3600);
    expect(b.points.map((p: number[]) => p[0])).toEqual([NOW - 5000, NOW - 3000, NOW - 10]);
    expect(b.points[0]).toEqual([NOW - 5000, 1, (NOW - 5000) / 1e6]);
  });

  it("a range with no rows inside returns just the baseline", async () => {
    const b = await body(seed([NOW - 9000, NOW - 5000]), "?range=1h");
    expect(b.points.map((p: number[]) => p[0])).toEqual([NOW - 5000]);
  });

  it("all: everything, thinned to <= 300 keeping first and last; from = first t", async () => {
    const ts = Array.from({ length: 1000 }, (_, i) => NOW - 100_000 + i * 100);
    const b = await body(seed(ts), "?range=all");
    expect(b.points.length).toBeLessThanOrEqual(301);
    expect(b.points[0][0]).toBe(ts[0]);
    expect(b.points.at(-1)[0]).toBe(ts.at(-1));
    expect(b.from).toBe(ts[0]);
  });

  it("unknown range is a 400; cache header set", async () => {
    expect((await handleChirpHistory(seed([]), get("?range=2h"), NOW)).status).toBe(400);
    // Inherited Object keys are not ranges: `in` let these through and the worker threw (Cloudflare 1101).
    for (const r of ["constructor", "__proto__", "toString", "hasOwnProperty"]) {
      expect((await handleChirpHistory(seed([]), get(`?range=${r}`), NOW)).status).toBe(400);
    }
    const res = await handleChirpHistory(seed([NOW]), get("?range=24h"), NOW);
    expect(res.headers.get("cache-control")).toBe("public, max-age=10");
  });

  it("an old baseline does not starve a dense range of points", async () => {
    const ts = [NOW - 3 * 86_400, ...Array.from({ length: 361 }, (_, i) => NOW - 3600 + i * 10)];
    const b = await body(seed(ts), "?range=1h");
    expect(b.points.length).toBeGreaterThan(150); // thin keeps ~every 12s: 181, not 7
    expect(b.points[0][0]).toBe(NOW - 3 * 86_400);
  });

  it("long ranges read hourly/5-minute rollups, not every reading", async () => {
    const db = seed([]);
    // A reading every 10s for 3 days: 25,920 rows through handleChirp's writer.
    for (let t = NOW - 3 * 86_400; t <= NOW; t += 10) {
      for (const st of pointWrites(db, [t, 1, t / 1e6])) await st.run();
    }
    const rollups = (g: number) => (db.raw.prepare("SELECT COUNT(*) AS n FROM rollup WHERE g = ?").get(g) as { n: number }).n;
    expect(rollups(300)).toBe(865);
    expect(rollups(3600)).toBe(73);
    const all = await body(db, "?range=all");
    expect(all.points.at(-1)[0]).toBe(NOW);
    expect(all.points.length).toBeLessThanOrEqual(301);
    const day = await body(db, "?range=24h");
    expect(day.points.length).toBeGreaterThan(250);
    expect(day.points.at(-1)[0]).toBe(NOW);
  });
});
