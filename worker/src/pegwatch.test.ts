import { describe, it, expect } from "vitest";
import { dailyText, sowText, launchText, pegWatchTick, postMode, runPegWatch, type Live, type EventRow, type LaunchRow } from "./pegwatch";
import { testDb } from "./test-d1";
import { readFileSync } from "node:fs";
import { PEG_WATCH_CRON } from "./pegwatch";

const LIVE: Live = { t: 1795132663, pintoUsd: 0.01855798, chirpUsd: 0.00018561691596 };
const clean = (s: string) => {
  expect(/https?:|\.com|\.xyz/.test(s)).toBe(false);
  expect(s.length).toBeLessThanOrEqual(280);
};
const sow = (pinto: string, pods: string | null): EventRow => ({
  block: 1, log: 0, tx: "0x1", t: 0, kind: "sow", pinto, chirp: "0", extra: pods === null ? null : JSON.stringify({ pods }),
});

describe("post text", () => {
  it("daily with a 24h change", () => {
    const s = dailyText(LIVE, { date: "2026-11-20", pintoChange: -1.234 });
    expect(s).toBe("🌾 Pinto · Nov 20\nPinto $0.0186 (−1.2% in 24h)\nChirp $0.000186");
    clean(s);
  });

  it("daily: rising, and no history", () => {
    expect(dailyText(LIVE, { date: "2026-11-20", pintoChange: 3.06 }).split("\n")[1]).toBe("Pinto $0.0186 (+3.1% in 24h)");
    expect(dailyText(LIVE, { date: "2026-11-20", pintoChange: null }).split("\n")[1]).toBe("Pinto $0.0186");
  });

  it("sow states the rate the sow got, from its pods", () => {
    const s = sowText(sow("25000000", "1025000000"));
    expect(s).toBe("Chirp's book sowed 25 Pinto into Pinto's Field at 4,000%.");
    clean(s);
    expect(sowText(sow("25000000", null))).toBe("Chirp's book sowed 25 Pinto into Pinto's Field.");
  });
});

// 2026-11-20 15:00:00 UTC
const AT15 = Date.UTC(2026, 10, 20, 15, 0, 0);
const MORNING = Date.UTC(2026, 10, 20, 9, 0, 0);
const sec = (ms: number) => Math.floor(ms / 1000);
type DB = ReturnType<typeof testDb>;

function setup(nowMs = AT15) {
  const db = testDb();
  db.raw.prepare("INSERT OR REPLACE INTO live (k, t, body) VALUES ('chirp', ?, ?)").run(nowMs, JSON.stringify({ ...LIVE, t: sec(nowMs) }));
  return db;
}
function setLive(db: DB, nowMs: number) {
  db.raw.prepare("UPDATE live SET body = ? WHERE k = 'chirp'").run(JSON.stringify({ ...LIVE, t: sec(nowMs) }));
}
function addEvent(db: DB, block: number, kind: EventRow["kind"], t: number, pinto = "25000000", pods = "1025000000") {
  db.raw.prepare("INSERT INTO events (block, log, tx, t, kind, who, pinto, chirp, extra) VALUES (?, 0, ?, ?, ?, NULL, ?, '12400000000000000000000', ?)")
    .run(block, `0x${block}`, t, kind, pinto, kind === "sow" ? JSON.stringify({ pods }) : null);
}
const watch = (db: DB) => JSON.parse((db.raw.prepare("SELECT body FROM live WHERE k='xwatch'").get() as { body: string }).body);
const rows = (db: DB) => db.raw.prepare("SELECT key, status, text FROM xposts ORDER BY rowid").all() as { key: string; status: string; text: string }[];
function sender(ok = true) {
  const sent: string[] = [];
  return { sent, send: async (text: string) => (sent.push(text), { ok }) };
}

describe("pegWatchTick", () => {
  it("off does nothing", async () => {
    const db = setup();
    await pegWatchTick(db, "off", sender().send, AT15);
    expect(rows(db)).toEqual([]);
    expect(watch(db)).toEqual({});
  });

  it("first tick seeds without posting", async () => {
    const db = setup(AT15);
    for (const b of [10, 11, 12]) addEvent(db, b, "sow", sec(AT15) - 100);
    const s = sender();
    await pegWatchTick(db, "on", s.send, AT15);
    expect(rows(db)).toEqual([]);
    expect(s.sent).toEqual([]);
    expect(watch(db)).toEqual({ block: 12, log: 0 });
  });

  it("a new sow posts once; trades and burns do not post", async () => {
    const db = setup(MORNING);
    const s = sender();
    await pegWatchTick(db, "on", s.send, MORNING);
    addEvent(db, 20, "buy", sec(MORNING));
    addEvent(db, 21, "sow", sec(MORNING));
    addEvent(db, 22, "buyback", sec(MORNING));
    await pegWatchTick(db, "on", s.send, MORNING + 600_000);
    expect(rows(db).map((r) => [r.key, r.status])).toEqual([["event:0x21:0", "sent"]]);
    expect(s.sent).toEqual(["Chirp's book sowed 25 Pinto into Pinto's Field at 4,000%."]);
    expect(watch(db)).toEqual({ block: 22, log: 0 });
  });

  it("same key twice posts once", async () => {
    const db = setup(MORNING);
    const s = sender();
    await pegWatchTick(db, "on", s.send, MORNING);
    addEvent(db, 20, "sow", sec(MORNING));
    const before = db.raw.prepare("SELECT body FROM live WHERE k='xwatch'").get() as { body: string };
    await pegWatchTick(db, "on", s.send, MORNING + 1000);
    db.raw.prepare("UPDATE live SET body = ? WHERE k='xwatch'").run(before.body); // an overlapping run read the old cursor
    await pegWatchTick(db, "on", s.send, MORNING + 2000);
    expect(s.sent.length).toBe(1);
  });

  it("dry writes status dry, never sends", async () => {
    const db = setup(MORNING);
    const s = sender();
    await pegWatchTick(db, "dry", s.send, MORNING);
    addEvent(db, 20, "sow", sec(MORNING));
    await pegWatchTick(db, "dry", s.send, MORNING + 1000);
    expect(rows(db).map((r) => r.status)).toEqual(["dry"]);
    expect(s.sent).toEqual([]);
  });

  it("daily at 15:00 UTC once", async () => {
    const db = setup(AT15 - 60_000);
    const s = sender();
    await pegWatchTick(db, "on", s.send, AT15 - 60_000); // seed
    await pegWatchTick(db, "on", s.send, AT15 - 1000);
    expect(rows(db)).toEqual([]);
    setLive(db, AT15);
    await pegWatchTick(db, "on", s.send, AT15);
    setLive(db, AT15 + 600_000);
    await pegWatchTick(db, "on", s.send, AT15 + 600_000);
    expect(rows(db).map((r) => r.key)).toEqual(["daily:2026-11-20"]);
    expect(s.sent[0]).toBe(dailyText(LIVE, { date: "2026-11-20", pintoChange: null }));
  });

  it("daily change uses the reading nearest 24h ago, within an hour", async () => {
    const db = setup(AT15);
    await pegWatchTick(db, "dry", sender().send, AT15 - 1000); // seed
    const ago = sec(AT15) - 86_400;
    db.raw.prepare("INSERT INTO points (t, pinto, chirp) VALUES (?, ?, 0)").run(ago - 7200, 0.5); // too old to use
    db.raw.prepare("INSERT INTO points (t, pinto, chirp) VALUES (?, ?, 0)").run(ago + 600, 0.02);
    await pegWatchTick(db, "dry", sender().send, AT15);
    expect(rows(db)[0].text.split("\n")[1]).toBe("Pinto $0.0186 (−7.2% in 24h)");
  });

  it("cap keeps a slot for daily", async () => {
    const db = setup(AT15);
    await pegWatchTick(db, "on", sender().send, AT15 - 1000); // seed
    for (let b = 40; b < 48; b++) addEvent(db, b, "sow", sec(AT15) - 10);
    const s = sender();
    await pegWatchTick(db, "on", s.send, AT15);
    const keys = rows(db).map((r) => r.key);
    expect(keys.filter((k) => k.startsWith("event:")).length).toBe(5);
    expect(keys.filter((k) => k.startsWith("daily:")).length).toBe(1);
    expect(s.sent.length).toBe(6);
    await pegWatchTick(db, "on", s.send, AT15 + 600_000);
    expect(s.sent.length).toBe(6);
  });

  it("stale live posts nothing", async () => {
    const db = setup(AT15 - 31 * 60_000);
    await pegWatchTick(db, "on", sender().send, AT15 - 31 * 60_000); // seed while fresh
    const s = sender();
    await pegWatchTick(db, "on", s.send, AT15);
    expect(rows(db)).toEqual([]);
    expect(s.sent).toEqual([]);
  });

  it("a refused send records X's status in the row", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "on", sender().send, MORNING);
    db.raw.prepare("INSERT INTO xposts (key, t, day, text, status) VALUES ('manual:intro', 0, '2026-11-20', 'hello', 'queued')").run();
    await pegWatchTick(db, "on", async () => ({ ok: false, status: 402 }), MORNING + 1000);
    expect(rows(db).map((r) => r.status)).toEqual(["failed:402"]);
  });

  it("failed send is not retried", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "on", sender().send, MORNING);
    addEvent(db, 20, "sow", sec(MORNING));
    await pegWatchTick(db, "on", sender(false).send, MORNING + 1000);
    expect(rows(db).map((r) => r.status)).toEqual(["failed"]);
    const s = sender();
    await pegWatchTick(db, "on", s.send, MORNING + 2000);
    expect(s.sent).toEqual([]);
  });

  it("a throwing send marks failed and does not stop the tick", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "on", sender().send, MORNING);
    addEvent(db, 20, "sow", sec(MORNING));
    addEvent(db, 21, "sow", sec(MORNING));
    let n = 0;
    const send = async () => {
      if (n++ === 0) throw new Error("network");
      return { ok: true };
    };
    await pegWatchTick(db, "on", send, MORNING + 1000);
    expect(rows(db).map((r) => r.status)).toEqual(["failed", "sent"]);
  });

  it("old sows are not posted as news, and the cursor moves past them", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "on", sender().send, MORNING);
    addEvent(db, 20, "sow", sec(MORNING) - 3 * 86_400); // a late backfill
    const s = sender();
    await pegWatchTick(db, "on", s.send, MORNING + 1000);
    expect(rows(db)).toEqual([]);
    expect(watch(db).block).toBe(20);
  });

  it("a queued post is sent once, on the next tick", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "on", sender().send, MORNING); // seed
    db.raw.prepare("INSERT INTO xposts (key, t, day, text, status) VALUES ('manual:intro', 0, '2026-11-20', 'hello', 'queued')").run();
    const s = sender();
    await pegWatchTick(db, "on", s.send, MORNING + 1000);
    await pegWatchTick(db, "on", s.send, MORNING + 2000);
    expect(s.sent).toEqual(["hello"]);
    expect(rows(db).map((r) => r.status)).toEqual(["sent"]);
  });

  it("a queued post stays queued in dry", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "dry", sender().send, MORNING);
    db.raw.prepare("INSERT INTO xposts (key, t, day, text, status) VALUES ('manual:intro', 0, '2026-11-20', 'hello', 'queued')").run();
    const s = sender();
    await pegWatchTick(db, "dry", s.send, MORNING + 1000);
    expect(s.sent).toEqual([]);
    expect(rows(db).map((r) => r.status)).toEqual(["queued"]);
  });

  it("dust sows under 1 Pinto are skipped", async () => {
    const db = setup(MORNING);
    await pegWatchTick(db, "on", sender().send, MORNING);
    addEvent(db, 20, "sow", sec(MORNING), "999999", "40000000");
    const s = sender();
    await pegWatchTick(db, "on", s.send, MORNING + 1000);
    expect(s.sent).toEqual([]);
  });
});

describe("runPegWatch", () => {
  const KEYS = { X_API_KEY: "k", X_API_SECRET: "s", X_ACCESS_TOKEN: "t", X_ACCESS_SECRET: "SUPERSECRET-abc" };

  it("parses mode: unknown → off, on without all keys → dry", () => {
    expect(postMode(undefined, KEYS)).toBe("off");
    expect(postMode("yes", KEYS)).toBe("off");
    expect(postMode("dry", KEYS)).toBe("dry");
    expect(postMode("on", KEYS)).toBe("on");
    expect(postMode("on", { ...KEYS, X_ACCESS_SECRET: undefined })).toBe("dry");
  });

  it("refreshes, then ticks", async () => {
    const db = setup(MORNING);
    const order: string[] = [];
    await runPegWatch({ CHIRP_DB: db, X_POSTS: "dry", ...KEYS }, async () => void order.push("refresh"), MORNING, async () => ({ ok: true }), () => {});
    expect(order).toEqual(["refresh"]);
    expect(watch(db)).not.toEqual({}); // the tick ran: first run seeds
  });

  it("a failing refresh or tick is logged with secrets redacted and never throws", async () => {
    const db = setup(MORNING);
    const logs: string[] = [];
    await runPegWatch(
      { CHIRP_DB: db, X_POSTS: "on", ...KEYS },
      async () => { throw new Error("rpc down SUPERSECRET-abc"); },
      MORNING,
      async () => ({ ok: true }),
      (m) => logs.push(m),
    );
    const broken = { ...db, prepare: () => { throw new Error("d1 boom SUPERSECRET-abc"); } };
    await runPegWatch({ CHIRP_DB: broken as never, X_POSTS: "on", ...KEYS }, async () => {}, MORNING, async () => ({ ok: true }), (m) => logs.push(m));
    expect(logs.length).toBe(2);
    for (const l of logs) {
      expect(l).not.toContain("SUPERSECRET-abc");
      expect(l).toContain("[secret redacted]");
    }
  });
});

describe("cron wiring", () => {
  it("wrangler.example.jsonc schedules the peg watch cron string the worker dispatches on", () => {
    const wrangler = readFileSync(new URL("../wrangler.example.jsonc", import.meta.url), "utf8");
    const crons = /"crons":\s*\[([^\]]*)\]/.exec(wrangler)![1];
    expect(crons).toContain(`"${PEG_WATCH_CRON}"`);
  });
});

describe("launcher coin autoposting", () => {
  const FACTORY = "0xf3a050114d4310bef64660a68332169eb76d0d70";
  const addCoin = (
    db: DB,
    c: Partial<LaunchRow> & { coin: string; launched_block: number; launched_at: number; hidden?: number },
  ) => {
    db.raw
      .prepare(
        `INSERT INTO launcher_coins (
          factory, coin, vault, pool_id, coin_is_token0, launcher, creator_payout,
          mode, fee_bps, creator_bps, name, symbol, image_uri, launched_block, launched_at, first_buy_weth, hidden
        ) VALUES (?, ?, '0xvault', '0xpool', 1, '0xlauncher', '0xcreator', ?, ?, 1000, ?, ?, '', ?, ?, '0', ?)`,
      )
      .run(
        FACTORY,
        c.coin.toLowerCase(),
        c.mode ?? 1,
        c.fee_bps ?? 100,
        c.name ?? "Chuck",
        c.symbol ?? "CHUCK",
        c.launched_block,
        c.launched_at,
        c.hidden ?? 0,
      );
  };

  it("launchText formats burn & redeem coins and strips URLs, domains, and @mentions", () => {
    const burn = launchText({
      coin: "0x62fbb2379cb12b75c1cdaffbb69f61757e89288d",
      name: "Chuck",
      symbol: "Chuck",
      mode: 1,
      fee_bps: 100,
      launched_block: 100,
      launched_at: 1000,
    });
    expect(burn).toBe("🌱 New coin on Surco: Chuck ($CHUCK)\nBurn mode · 1% fee · backed by Pinto in the Silo on Base.");
    clean(burn);

    const redeem = launchText({
      coin: "0x222",
      name: "Visit https://evil.com @victim bad.xyz\nCoin",
      symbol: "@scam.io",
      mode: 0,
      fee_bps: 150,
      launched_block: 101,
      launched_at: 1000,
    });
    expect(redeem).toBe("🌱 New coin on Surco: Visit victim Coin\nRedeem mode · 1.5% fee · backed by Pinto in the Silo on Base.");
    expect(redeem).not.toContain("@");
    clean(redeem);
  });

  it("seeds launchBlock without replaying old coins, then posts new launches once (skipping hidden and stale)", async () => {
    const db = setup(MORNING);
    const s = sender();
    // Pre-existing coin before enabling launch posts
    addCoin(db, { coin: "0xold1", name: "Old", symbol: "OLD", launched_block: 100, launched_at: sec(MORNING) - 60 });
    await pegWatchTick(db, "on", s.send, MORNING, { launcherFactory: FACTORY });
    expect(s.sent).toEqual([]);
    expect(watch(db)).toEqual({ block: 0, log: 0, launchBlock: 100 });

    // Add 3 new coins: 1 stale, 1 hidden, 1 fresh
    addCoin(db, { coin: "0xstale", name: "Stale", symbol: "STL", launched_block: 101, launched_at: sec(MORNING) - 5000 });
    addCoin(db, { coin: "0xhidden", name: "Hidden", symbol: "HID", launched_block: 102, launched_at: sec(MORNING), hidden: 1 });
    addCoin(db, { coin: "0xfresh", name: "Sprout", symbol: "SPRT", mode: 0, fee_bps: 50, launched_block: 103, launched_at: sec(MORNING) });

    await pegWatchTick(db, "on", s.send, MORNING + 60_000, { launcherFactory: FACTORY });
    expect(rows(db).map((r) => [r.key, r.status])).toEqual([["launch:0xfresh", "sent"]]);
    expect(s.sent).toEqual([
      "🌱 New coin on Surco: Sprout ($SPRT)\nRedeem mode · 0.5% fee · backed by Pinto in the Silo on Base.",
    ]);
    expect(watch(db)).toEqual({ block: 0, log: 0, launchBlock: 103 });

    // Re-running with old cursor never double-posts
    db.raw.prepare("UPDATE live SET body = ? WHERE k='xwatch'").run(JSON.stringify({ block: 0, log: 0, launchBlock: 100 }));
    await pegWatchTick(db, "on", s.send, MORNING + 120_000, { launcherFactory: FACTORY });
    expect(s.sent.length).toBe(1);
  });
});
