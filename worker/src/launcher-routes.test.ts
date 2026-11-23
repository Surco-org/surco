import { describe, expect, it } from "vitest";
import { testDb } from "./test-d1";
import type { LauncherConfig } from "./launcher-config";
import { computePoolId, type LauncherRpc } from "./launcher-index";
import { handleAttachCoinMeta, handleLauncherCoin, handleLauncherCoins, handleLauncherCreator } from "./launcher-routes";
import { handleMetaUpload, type R2BucketLike } from "./launcher-images";
import type { Address, Hex } from "viem";

const CFG: LauncherConfig = {
  factory: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  hook: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  safe: "0xcccccccccccccccccccccccccccccccccccccccc",
  deployBlock: 60_330_327,
  isTest: true,
};

const COIN_A = "0xdddddddddddddddddddddddddddddddddddddddd" as Address;
const VAULT_A = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as Address;
const COIN_B = "0x2222222222222222222222222222222222222222" as Address;
const VAULT_B = "0x3333333333333333333333333333333333333333" as Address;
const CREATOR = "0x9999999999999999999999999999999999999999" as Address;

async function seedCoins() {
  const db = testDb();
  const f = CFG.factory.toLowerCase();
  const pA = computePoolId(COIN_A, CFG.hook);
  const pB = computePoolId(COIN_B, CFG.hook);
  await db
    .prepare("INSERT INTO launcher_state (factory, cursor_block, last_refresh_ms, weth_usd, pinto_usd) VALUES (?, ?, ?, ?, ?)")
    .bind(f, 60_330_500, 1_795_000_000_000, 3000, 0.02)
    .run();
  await db
    .prepare(
      `INSERT INTO launcher_coins
      (factory, coin, vault, pool_id, launcher, creator_payout, mode, fee_bps, creator_bps, name, symbol, image_uri, coin_is_token0, launched_block, launched_at, hidden, price_weth, silo_pinto, silo_pinto_num, unsplit_weth, vol_24h_weth, creator_paid_weth)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(f, COIN_A, VAULT_A, pA.poolId, CREATOR, CREATOR, 1, 100, 1000, "Demo Burn", "DEMO", "", 0, 60_330_330, 1_794_999_000, 0, 1e-8, "30550000", 30.55, "1000000000000000", 0.5, "200000000000000")
    .run();
  await db
    .prepare(
      `INSERT INTO launcher_coins
      (factory, coin, vault, pool_id, launcher, creator_payout, mode, fee_bps, creator_bps, name, symbol, image_uri, coin_is_token0, launched_block, launched_at, hidden, hidden_reason, price_weth, silo_pinto, silo_pinto_num, unsplit_weth, vol_24h_weth, creator_paid_weth)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(f, COIN_B, VAULT_B, pB.poolId, CREATOR, CREATOR, 0, 100, 2000, "Hidden Scam", "SCAM", "", 1, 60_330_335, 1_794_999_500, 1, "spam", 2e-8, "1000000", 1, "0", 10, "0")
    .run();
  return db;
}

describe("launcher-routes", () => {
  it("lists only non-hidden coins on /api/launcher/coins and rejects prototype sort keys", async () => {
    const db = await seedCoins();
    const res = await handleLauncherCoins(
      db,
      new URL("https://surcofi.com/api/launcher/coins?sort=constructor"),
      CFG,
      null,
      1_795_000_000_000,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { total: number; coins: { symbol: string; fdvUsd: number }[] };
    expect(body.total).toBe(1);
    expect(body.coins).toHaveLength(1);
    expect(body.coins[0].symbol).toBe("DEMO");
    expect(body.coins[0].fdvUsd).toBeCloseTo(30_000, 0);
  });

  it("still resolves a hidden coin directly on /api/launcher/coin?a=...", async () => {
    const db = await seedCoins();
    const res = await handleLauncherCoin(
      db,
      new URL(`https://surcofi.com/api/launcher/coin?a=${COIN_B}&range=__proto__`),
      CFG,
      null,
      1_795_000_000_000,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { coin: { symbol: string; hidden: boolean }; chart: { range: string } };
    expect(body.coin.symbol).toBe("SCAM");
    expect(body.coin.hidden).toBe(true);
    expect(body.chart.range).toBe("24h");
  });

  it("falls back to live RPC when a brand-new coin is not yet in D1", async () => {
    const db = await seedCoins();
    const freshCoin = "0x4444444444444444444444444444444444444444" as Address;
    const freshVault = "0x5555555555555555555555555555555555555555" as Address;
    const slotWord = (`0x${(1n << 96n).toString(16).padStart(64, "0")}`) as Hex;
    const rpc: LauncherRpc = {
      getBlockNumber: async () => 60_330_500,
      getLogs: async () => [],
      multicall: async () => [],
      multicallOptional: async (calls) => {
        if (calls.length === 1) {
          return [{ status: "success", result: [freshVault, 100, 1_795_000_000n, false, 0n, 0n] }];
        }
        return [
          { status: "success", result: "Fresh Coin" },
          { status: "success", result: "FRESH" },
          { status: "success", result: "" },
          { status: "success", result: 1_000_000_000n * 10n ** 18n },
          { status: "success", result: CREATOR },
          { status: "success", result: 1000 },
          { status: "success", result: 0n },
          { status: "success", result: 0n },
          { status: "success", result: 0n },
          { status: "success", result: slotWord },
          { status: "failure" }, // Redeem mode (no yieldPinto)
        ];
      },
    };
    const res = await handleLauncherCoin(
      db,
      new URL(`https://surcofi.com/api/launcher/coin?a=${freshCoin}`),
      CFG,
      rpc,
      1_795_000_000_000,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { liveFallback: boolean; coin: { symbol: string; mode: string } };
    expect(body.liveFallback).toBe(true);
    expect(body.coin.symbol).toBe("FRESH");
    expect(body.coin.mode).toBe("redeem");
  });

  it("computes creator paid and claimable WETH totals on /api/launcher/creator", async () => {
    const db = await seedCoins();
    const res = await handleLauncherCreator(
      db,
      new URL(`https://surcofi.com/api/launcher/creator?a=${CREATOR}`),
      CFG,
      null,
      1_795_000_000_000,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { totals: { paidWeth: string; claimableWeth: string }; coins: unknown[] };
    expect(body.coins).toHaveLength(2);
    expect(body.totals.paidWeth).toBe("200000000000000");
    // 10% of 1e15 unsplit = 1e14
    expect(body.totals.claimableWeth).toBe("100000000000000");
  });

  it("returns 400 on invalid addresses", async () => {
    const db = await seedCoins();
    expect((await handleLauncherCoin(db, new URL("https://surcofi.com/api/launcher/coin?a=notanaddr"), CFG, null, 0)).status).toBe(400);
    expect((await handleLauncherCreator(db, new URL("https://surcofi.com/api/launcher/creator?a=0x123"), CFG, null, 0)).status).toBe(400);
  });

  it("persists coin-meta attached before the 5-block indexer settle and serves it on liveFallback", async () => {
    const db = await seedCoins();
    const store = new Map<string, Uint8Array<ArrayBuffer>>();
    const bucket: R2BucketLike = {
      async put(k, v) {
        const copy = new Uint8Array(new ArrayBuffer(v.byteLength));
        copy.set(v instanceof Uint8Array ? v : new Uint8Array(v));
        store.set(k, copy);
      },
      async get(k) {
        const b = store.get(k);
        if (!b) return null;
        return { body: b, async arrayBuffer() { return b.buffer.slice(0); } };
      },
    };
    const metaRes = await handleMetaUpload(
      new Request("https://surcofi.com/api/launcher/meta", {
        method: "POST",
        body: JSON.stringify({ name: "Fresh Coin", symbol: "FRESH", website: "https://surcofi.com" }),
      }),
      bucket,
      "https://surcofi.com",
    );
    const { key } = (await metaRes.json()) as { key: string };

    const freshCoin = "0x4444444444444444444444444444444444444444" as Address;
    const freshVault = "0x5555555555555555555555555555555555555555" as Address;
    const slotWord = (`0x${(1n << 96n).toString(16).padStart(64, "0")}`) as Hex;
    const rpc: LauncherRpc = {
      getBlockNumber: async () => 60_330_500,
      getLogs: async () => [],
      multicall: async () => [],
      multicallOptional: async (calls) => {
        if (calls.length === 1) return [{ status: "success", result: [freshVault, 100, 1_795_000_000n, false, 0n, 0n] }];
        return [
          { status: "success", result: "Fresh Coin" },
          { status: "success", result: "FRESH" },
          { status: "success", result: "" },
          { status: "success", result: 1_000_000_000n * 10n ** 18n },
          { status: "success", result: CREATOR },
          { status: "success", result: 1000 },
          { status: "success", result: 0n },
          { status: "success", result: 0n },
          { status: "success", result: 0n },
          { status: "success", result: slotWord },
          { status: "failure" },
          { status: "failure" },
        ];
      },
    };

    // Attach BEFORE coin is in launcher_coins
    const att = await handleAttachCoinMeta(
      new Request("https://surcofi.com/api/launcher/coin-meta", {
        method: "POST",
        body: JSON.stringify({ coin: freshCoin, key }),
      }),
      db,
      bucket,
      CFG,
      rpc,
      "https://surcofi.com",
    );
    expect(att.status).toBe(200);

    // Second attach attempt is rejected (write-once)
    const att2 = await handleAttachCoinMeta(
      new Request("https://surcofi.com/api/launcher/coin-meta", {
        method: "POST",
        body: JSON.stringify({ coin: freshCoin, key }),
      }),
      db,
      bucket,
      CFG,
      rpc,
      "https://surcofi.com",
    );
    expect(att2.status).toBe(409);

    // Immediate /api/launcher/coin liveFallback returns the attached websiteUrl!
    const coinRes = await handleLauncherCoin(
      db,
      new URL(`https://surcofi.com/api/launcher/coin?a=${freshCoin}`),
      CFG,
      rpc,
      1_795_000_000_000,
      bucket,
    );
    const body = (await coinRes.json()) as { coin: { websiteUrl: string; metadataUri: string } };
    expect(body.coin.websiteUrl).toBe("https://surcofi.com/");
    expect(body.coin.metadataUri).toContain(key);
  });
});
