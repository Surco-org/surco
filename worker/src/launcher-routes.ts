// HTTP API handlers for /api/launcher/coins, /api/launcher/coin, and /api/launcher/creator.
import { isAddress, type Address } from "viem";
import type { D1Like } from "./chirp";
import { LAUNCHER_LP_FEE, LAUNCHER_TICK_SPACING, LAUNCHER_TOLL_WINDOW, BASE_WETH, type LauncherConfig } from "./launcher-config";
import { readStoredMeta, type R2BucketLike } from "./launcher-images";
import {
  ensureLauncherState,
  indexLauncherIfDue,
  readSingleCoinLive,
  type CoinRow,
  type LauncherRpc,
} from "./launcher-index";

const json = (body: unknown, status = 200, maxAge = 5) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": `public, max-age=${maxAge}` },
  });

const SORTS: Record<string, string> = {
  activity: "vol_24h_weth DESC, last_swap_at DESC, launched_at DESC",
  backing: "silo_pinto_num DESC, launched_at DESC",
  newest: "launched_at DESC, launched_block DESC",
};

const RANGES: Record<string, number | null> = {
  "1h": 3_600,
  "24h": 86_400,
  "7d": 604_800,
  all: null,
};

function allFactoryConfigs(cfg: LauncherConfig): LauncherConfig[] {
  const extras = (cfg.extraFactories ?? []).map((e) => ({
    ...cfg,
    factory: e.factory,
    hook: e.hook,
    deployBlock: e.deployBlock,
  }));
  return [cfg, ...extras];
}

function hookForFactory(factoryAddr: string, cfg: LauncherConfig): string {
  const f = factoryAddr.toLowerCase();
  if (f === cfg.factory.toLowerCase()) return cfg.hook.toLowerCase();
  const extra = (cfg.extraFactories ?? []).find((e) => e.factory.toLowerCase() === f);
  return (extra ? extra.hook : cfg.hook).toLowerCase();
}

function formatCoin(c: CoinRow, cfg: LauncherConfig, wethUsd: number, pintoUsd: number) {
  const supplyNum = Number(c.total_supply) / 1e18;
  const priceUsd = c.price_weth * wethUsd;
  const fdvWeth = c.price_weth * supplyNum;
  const fdvUsd = fdvWeth * wethUsd;
  const siloPintoUsd = c.silo_pinto_num * pintoUsd;
  const unsplit = BigInt(c.unsplit_weth || "0");
  const claimableCreatorWeth = (unsplit * BigInt(c.creator_bps)) / 10_000n;
  const currency0 = c.coin_is_token0 === 1 ? c.coin : BASE_WETH.toLowerCase();
  const currency1 = c.coin_is_token0 === 1 ? BASE_WETH.toLowerCase() : c.coin;

  return {
    coin: c.coin,
    factory: c.factory,
    vault: c.vault,
    poolId: c.pool_id,
    poolKey: {
      currency0,
      currency1,
      fee: LAUNCHER_LP_FEE,
      tickSpacing: LAUNCHER_TICK_SPACING,
      hooks: hookForFactory(c.factory, cfg),
    },
    coinIsToken0: c.coin_is_token0 === 1,
    launcher: c.launcher,
    creatorPayout: c.creator_payout,
    mode: c.mode === 1 ? "burn" : "redeem",
    feeBps: c.fee_bps,
    creatorBps: c.creator_bps,
    name: c.name,
    symbol: c.symbol,
    imageUri: c.image_uri,
    metadataUri: c.metadata_uri || "",
    websiteUrl: c.website_url || "",
    twitterUrl: c.twitter_url || "",
    description: c.description || "",
    launchedBlock: c.launched_block,
    launchedAt: c.launched_at,
    tollEndsAt: c.launched_at > 0 ? c.launched_at + LAUNCHER_TOLL_WINDOW : 0,
    firstBuyWeth: c.first_buy_weth,
    hidden: c.hidden === 1,
    priceWeth: c.price_weth,
    priceUsd,
    fdvWeth,
    fdvUsd,
    siloPinto: c.silo_pinto,
    siloPintoNum: c.silo_pinto_num,
    siloPintoUsd,
    yieldPinto: c.yield_pinto,
    pendingWeth: c.pending_weth,
    unsplitWeth: c.unsplit_weth,
    claimableCreatorWeth: String(claimableCreatorWeth),
    creatorPaidWeth: c.creator_paid_weth,
    totalSupply: c.total_supply,
    vol24hWeth: c.vol_24h_weth,
    vol24hUsd: c.vol_24h_weth * wethUsd,
    volAllWeth: c.vol_all_weth,
    trades24h: c.trades_24h,
    tradesAll: c.trades_all,
    lastSwapAt: c.last_swap_at,
  };
}

/** Thins chart points to at most `max` while keeping first and last point. */
function thinPoints(pts: [number, number][], max = 240): [number, number][] {
  if (pts.length <= max || pts.length <= 2) return pts;
  const gap = (pts[pts.length - 1][0] - pts[0][0]) / max;
  const out: [number, number][] = [pts[0]];
  for (let i = 1; i < pts.length - 1; i++) {
    if (pts[i][0] - out[out.length - 1][0] >= gap) out.push(pts[i]);
  }
  out.push(pts[pts.length - 1]);
  return out;
}

/** GET /api/launcher/coins?sort=activity|backing|newest&q=&limit=50&offset=0 */
export async function handleLauncherCoins(
  db: D1Like,
  url: URL,
  cfg: LauncherConfig,
  rpc: LauncherRpc | null,
  nowMs: number,
  bucket?: R2BucketLike,
): Promise<Response> {
  const cfgs = allFactoryConfigs(cfg);
  for (const c of cfgs) await indexLauncherIfDue(db, rpc, c, nowMs, bucket);
  const f = cfg.factory.toLowerCase();
  const factories = cfgs.map((c) => c.factory.toLowerCase());
  const inClause = factories.map(() => "?").join(", ");
  const state = await ensureLauncherState(db, cfg);

  const sortKey = (url.searchParams.get("sort") ?? "activity").toLowerCase();
  const orderBy = Object.hasOwn(SORTS, sortKey) ? SORTS[sortKey] : SORTS.activity;
  const qRaw = (url.searchParams.get("q") ?? "").trim().toLowerCase();
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") ?? 50) || 50));
  const offset = Math.max(0, Number(url.searchParams.get("offset") ?? 0) || 0);

  let rows: CoinRow[];
  let total: number;
  if (qRaw) {
    const like = `%${qRaw}%`;
    total =
      (
        await db
          .prepare(
            `SELECT COUNT(*) AS n FROM launcher_coins WHERE factory IN (${inClause}) AND hidden = 0 AND (LOWER(name) LIKE ? OR LOWER(symbol) LIKE ? OR coin = ?)`,
          )
          .bind(...factories, like, like, qRaw)
          .first<{ n: number }>()
      )?.n ?? 0;
    rows = (
      await db
        .prepare(
          `SELECT * FROM launcher_coins WHERE factory IN (${inClause}) AND hidden = 0 AND (LOWER(name) LIKE ? OR LOWER(symbol) LIKE ? OR coin = ?) ORDER BY ${orderBy} LIMIT ? OFFSET ?`,
        )
        .bind(...factories, like, like, qRaw, limit, offset)
        .all<CoinRow>()
    ).results;
  } else {
    total =
      (
        await db
          .prepare(`SELECT COUNT(*) AS n FROM launcher_coins WHERE factory IN (${inClause}) AND hidden = 0`)
          .bind(...factories)
          .first<{ n: number }>()
      )?.n ?? 0;
    rows = (
      await db
        .prepare(`SELECT * FROM launcher_coins WHERE factory IN (${inClause}) AND hidden = 0 ORDER BY ${orderBy} LIMIT ? OFFSET ?`)
        .bind(...factories, limit, offset)
        .all<CoinRow>()
    ).results;
  }

  return json({
    factory: f,
    hook: cfg.hook.toLowerCase(),
    isTest: cfg.isTest,
    wethUsd: state.weth_usd,
    pintoUsd: state.pinto_usd,
    cursorBlock: state.cursor_block,
    total,
    coins: rows.map((r) => formatCoin(r, cfg, state.weth_usd, state.pinto_usd)),
  });
}

/** GET /api/launcher/coin?a=<address>&range=1h|24h|7d|all */
export async function handleLauncherCoin(
  db: D1Like,
  url: URL,
  cfg: LauncherConfig,
  rpc: LauncherRpc | null,
  nowMs: number,
  bucket?: R2BucketLike,
): Promise<Response> {
  const addrRaw = (url.searchParams.get("a") ?? "").trim();
  if (!isAddress(addrRaw)) return json({ error: "invalid coin address" }, 400, 0);
  const coinAddr = addrRaw.toLowerCase();

  const cfgs = allFactoryConfigs(cfg);
  for (const c of cfgs) await indexLauncherIfDue(db, rpc, c, nowMs, bucket);
  const factories = cfgs.map((c) => c.factory.toLowerCase());
  const inClause = factories.map(() => "?").join(", ");
  const state = await ensureLauncherState(db, cfg);

  let row = await db
    .prepare(`SELECT * FROM launcher_coins WHERE factory IN (${inClause}) AND coin = ?`)
    .bind(...factories, coinAddr)
    .first<CoinRow>();

  let liveFallback = false;
  if (!row && rpc) {
    for (const c of cfgs) {
      row = await readSingleCoinLive(rpc, c, addrRaw as Address, bucket);
      if (row) {
        liveFallback = true;
        break;
      }
    }
    if (row && !row.metadata_uri) {
      const pre = await db
        .prepare("SELECT metadata_uri, website_url, twitter_url, description FROM launcher_coin_meta WHERE factory = ? AND coin = ?")
        .bind(row.factory, coinAddr)
        .first<{ metadata_uri: string; website_url: string; twitter_url: string; description: string }>();
      if (pre) {
        row = {
          ...row,
          metadata_uri: pre.metadata_uri,
          website_url: pre.website_url,
          twitter_url: pre.twitter_url,
          description: pre.description,
        };
      }
    }
  }
  if (!row) return json({ error: "coin not found on this factory" }, 404, 0);
  const rowFactory = row.factory.toLowerCase();
  const rowHook = hookForFactory(rowFactory, cfg);

  const rangeKey = (url.searchParams.get("range") ?? "24h").toLowerCase();
  const spanSec = Object.hasOwn(RANGES, rangeKey) ? RANGES[rangeKey] : RANGES["24h"];
  const nowSec = Math.floor(nowMs / 1000);
  const fromSec = spanSec !== null ? nowSec - spanSec : 0;

  // Fetch chart swap points (plus 1 baseline point before fromSec so the step chart starts cleanly).
  const swapPts = (
    await db
      .prepare(
        "SELECT t, price_weth FROM launcher_swaps WHERE factory = ? AND pool_id = ? AND t >= ? ORDER BY t ASC, log_idx ASC LIMIT 2000",
      )
      .bind(rowFactory, row.pool_id, fromSec)
      .all<{ t: number; price_weth: number }>()
  ).results;

  const baseline =
    fromSec > 0
      ? await db
          .prepare(
            "SELECT t, price_weth FROM launcher_swaps WHERE factory = ? AND pool_id = ? AND t < ? ORDER BY t DESC, log_idx DESC LIMIT 1",
          )
          .bind(rowFactory, row.pool_id, fromSec)
          .first<{ t: number; price_weth: number }>()
      : null;

  const rawSeries: [number, number][] = [];
  if (baseline) rawSeries.push([fromSec, baseline.price_weth]);
  else if (row.launched_at > 0 && row.launched_at >= fromSec && swapPts.length === 0 && row.price_weth > 0) {
    rawSeries.push([row.launched_at, row.price_weth]);
  }
  for (const p of swapPts) rawSeries.push([p.t, p.price_weth]);
  if (row.price_weth > 0 && (rawSeries.length === 0 || nowSec > rawSeries[rawSeries.length - 1][0])) {
    rawSeries.push([nowSec, row.price_weth]);
  }

  // Recent swaps + vault events for the activity feed.
  const recentSwaps = (
    await db
      .prepare(
        "SELECT block, log_idx, tx, t, is_buy, weth_wei, coin_wei, price_weth FROM launcher_swaps WHERE factory = ? AND pool_id = ? ORDER BY block DESC, log_idx DESC LIMIT 40",
      )
      .bind(rowFactory, row.pool_id)
      .all<{
        block: number; log_idx: number; tx: string; t: number;
        is_buy: number; weth_wei: string; coin_wei: string; price_weth: number;
      }>()
  ).results;

  const recentVault = (
    await db
      .prepare(
        "SELECT block, log_idx, tx, t, kind, actor, amount_a, amount_b, tip FROM launcher_vault_events WHERE factory = ? AND vault = ? ORDER BY block DESC, log_idx DESC LIMIT 40",
      )
      .bind(rowFactory, row.vault)
      .all<{
        block: number; log_idx: number; tx: string; t: number;
        kind: string; actor: string | null; amount_a: string; amount_b: string; tip: string;
      }>()
  ).results;

  const activity = [
    ...recentSwaps.map((s) => ({
      block: s.block,
      logIdx: s.log_idx,
      tx: s.tx,
      t: s.t,
      kind: s.is_buy ? "buy" : "sell",
      wethWei: s.weth_wei,
      coinWei: s.coin_wei,
      priceWeth: s.price_weth,
    })),
    ...recentVault.map((v) => ({
      block: v.block,
      logIdx: v.log_idx,
      tx: v.tx,
      t: v.t,
      kind: v.kind,
      actor: v.actor,
      amountA: v.amount_a,
      amountB: v.amount_b,
      tip: v.tip,
    })),
  ]
    .sort((a, b) => b.block - a.block || b.logIdx - a.logIdx)
    .slice(0, 50);

  return json({
    factory: rowFactory,
    hook: rowHook,
    isTest: cfg.isTest,
    wethUsd: state.weth_usd,
    pintoUsd: state.pinto_usd,
    liveFallback,
    coin: formatCoin(row, cfg, state.weth_usd, state.pinto_usd),
    chart: {
      range: Object.hasOwn(RANGES, rangeKey) ? rangeKey : "24h",
      from: fromSec,
      points: thinPoints(rawSeries), // [t, priceWeth][]
    },
    activity,
  });
}

/** GET /api/launcher/creator?a=<address> */
export async function handleLauncherCreator(
  db: D1Like,
  url: URL,
  cfg: LauncherConfig,
  rpc: LauncherRpc | null,
  nowMs: number,
): Promise<Response> {
  const addrRaw = (url.searchParams.get("a") ?? "").trim();
  if (!isAddress(addrRaw)) return json({ error: "invalid address" }, 400, 0);
  const addr = addrRaw.toLowerCase();

  const cfgs = allFactoryConfigs(cfg);
  for (const c of cfgs) await indexLauncherIfDue(db, rpc, c, nowMs);
  const factories = cfgs.map((c) => c.factory.toLowerCase());
  const inClause = factories.map(() => "?").join(", ");
  const state = await ensureLauncherState(db, cfg);

  const rows = (
    await db
      .prepare(
        `SELECT * FROM launcher_coins WHERE factory IN (${inClause}) AND (creator_payout = ? OR launcher = ?) ORDER BY launched_at DESC`,
      )
      .bind(...factories, addr, addr)
      .all<CoinRow>()
  ).results;

  let totalPaid = 0n;
  let totalClaimable = 0n;
  const coins = rows.map((r) => {
    const formatted = formatCoin(r, cfg, state.weth_usd, state.pinto_usd);
    if (r.creator_payout === addr) {
      totalPaid += BigInt(r.creator_paid_weth || "0");
      totalClaimable += BigInt(formatted.claimableCreatorWeth);
    }
    return {
      ...formatted,
      isCurrentPayout: r.creator_payout === addr,
      isLauncher: r.launcher === addr,
    };
  });

  return json({
    factory: cfg.factory.toLowerCase(),
    isTest: cfg.isTest,
    address: addr,
    wethUsd: state.weth_usd,
    pintoUsd: state.pinto_usd,
    totals: {
      paidWeth: String(totalPaid),
      claimableWeth: String(totalClaimable),
      paidUsd: (Number(totalPaid) / 1e18) * state.weth_usd,
      claimableUsd: (Number(totalClaimable) / 1e18) * state.weth_usd,
    },
    coins,
  });
}

/**
 * POST /api/launcher/coin-meta — write-once fallback for coins launched on the TEST factory
 * (which predates on-chain `metadataURI`). Attaches an already-stored R2 metadata doc only if
 * its name & symbol match the coin on-chain and the coin has no metadata_uri set yet.
 */
export async function handleAttachCoinMeta(
  request: Request,
  db: D1Like,
  bucket: R2BucketLike | undefined,
  cfg: LauncherConfig,
  rpc: LauncherRpc | null,
  origin: string,
): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405, 0);
  if (!cfg.isTest) return json({ error: "coin metadata is immutable on-chain for this factory" }, 410, 0);
  let body: { coin?: string; key?: string };
  try {
    body = (await request.json()) as { coin?: string; key?: string };
  } catch {
    return json({ error: "invalid JSON" }, 400, 0);
  }
  const coinRaw = (body.coin ?? "").trim();
  const key = (body.key ?? "").trim();
  if (!isAddress(coinRaw)) return json({ error: "invalid coin address" }, 400, 0);
  const doc = await readStoredMeta(key, bucket);
  if (!doc) return json({ error: "metadata not found" }, 404, 0);

  const f = cfg.factory.toLowerCase();
  const coinAddr = coinRaw.toLowerCase();
  let row = await db
    .prepare("SELECT coin, name, symbol, metadata_uri FROM launcher_coins WHERE factory = ? AND coin = ?")
    .bind(f, coinAddr)
    .first<{ coin: string; name: string; symbol: string; metadata_uri: string }>();

  if (!row && rpc) {
    const live = await readSingleCoinLive(rpc, cfg, coinRaw as Address, bucket);
    if (live) {
      row = { coin: live.coin, name: live.name, symbol: live.symbol, metadata_uri: live.metadata_uri };
    }
  }
  if (!row) return json({ error: "coin not found on this factory" }, 404, 0);
  const existingPre = await db
    .prepare("SELECT metadata_uri FROM launcher_coin_meta WHERE factory = ? AND coin = ?")
    .bind(f, coinAddr)
    .first<{ metadata_uri: string }>();
  if (row.metadata_uri || existingPre?.metadata_uri) return json({ error: "metadata already set" }, 409, 0);
  if (row.name !== doc.name || row.symbol !== doc.symbol) {
    return json({ error: "metadata name/symbol does not match coin" }, 400, 0);
  }

  const base = origin.replace(/\/$/, "");
  const metaUrl = `${base}/api/launcher/meta/${key}`;
  const website = doc.website || doc.external_link || doc.links?.website || "";
  const twitter = doc.links?.twitter || "";
  const description = doc.description || "";

  await db.batch([
    db
      .prepare(
        "INSERT OR IGNORE INTO launcher_coin_meta (factory, coin, metadata_uri, website_url, twitter_url, description) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .bind(f, coinAddr, metaUrl, website, twitter, description),
    db
      .prepare(
        "UPDATE launcher_coins SET metadata_uri = ?, website_url = ?, twitter_url = ?, description = ? WHERE factory = ? AND coin = ? AND metadata_uri = ''",
      )
      .bind(metaUrl, website, twitter, description, f, coinAddr),
  ]);

  return json({ ok: true, metadataUri: metaUrl, websiteUrl: website, twitterUrl: twitter, description }, 200, 0);
}
