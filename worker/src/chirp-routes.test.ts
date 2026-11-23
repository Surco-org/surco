import { describe, expect, it } from "vitest";
import { handleActivity, handleHolders } from "./chirp-routes";
import { testDb } from "./test-d1";

function seed() {
  const db = testDb();
  const ins = db.raw.prepare("INSERT INTO events VALUES (?, ?, ?, 100, 'buy', '0xa', '1', '2', NULL)");
  for (let b = 1; b <= 60; b++) ins.run(b, 0, `0xt${b}`);
  ins.run(60, 1, "0xt60b");
  db.raw.exec("INSERT INTO holders VALUES ('0xsmall', '5', 5e-18), ('0xbig', '7000000000000000000', 7), ('0xmid', '2000000000000000000', 2)");
  return db;
}
const get = (path: string) => new URL(`https://surcofi.com${path}`);

describe("chirp routes", () => {
  it("activity: 50 newest, then pages strictly before the cursor", async () => {
    const db = seed();
    const res = await handleActivity(db, get("/api/chirp/activity"));
    expect(res.headers.get("cache-control")).toBe("public, max-age=10");
    const { rows } = await res.json();
    expect(rows).toHaveLength(50);
    expect([rows[0].block, rows[0].log]).toEqual([60, 1]);
    expect([rows[1].block, rows[1].log]).toEqual([60, 0]);
    const last = rows[49];
    const next = (await (await handleActivity(db, get(`/api/chirp/activity?before=${last.block}-${last.log}`))).json()).rows;
    expect(next.map((r: { block: number }) => r.block)).toEqual([11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]);
  });

  it("activity: a malformed cursor is a 400", async () => {
    expect((await handleActivity(seed(), get("/api/chirp/activity?before=abc"))).status).toBe(400);
  });

  it("holders: ordered by balance with the total count", async () => {
    const body = await (await handleHolders(seed())).json();
    expect(body.count).toBe(3);
    expect(body.rows.map((r: { addr: string }) => r.addr)).toEqual(["0xbig", "0xmid", "0xsmall"]);
    expect(body.rows[0]).toEqual({ addr: "0xbig", bal: "7000000000000000000" });
  });
});
