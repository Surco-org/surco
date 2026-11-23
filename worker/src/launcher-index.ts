// Pinto Launcher D1 indexer & live chain reader.
// Mirrors chirp-index.ts: atomic `launcher_ranges` PK prevents double-application across concurrent
// refreshes, bounded block spans (auto-halving on 400s) respect Alchemy getLogs limits, and writes
// are capped per pass to fit comfortably inside Cloudflare Workers D1 budgets.
import {
  decodeEventLog,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  pad,
  parseAbi,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import type { D1Like, Multicall } from "./chirp";
import type { RawLog } from "./chirp-index";
import { readStoredMeta, type R2BucketLike } from "./launcher-images";
import {
  BASE_PINTO,
  BASE_POOL_MANAGER,
  BASE_USDC,
  BASE_USDC_WELL,
  BASE_WETH,
  BASE_WETH_USDC_POOL,
  LAUNCHER_LP_FEE,
  LAUNCHER_TICK_SPACING,
  type LauncherConfig,
} from "./launcher-config";

export const LAUNCHER_FRESH_MS = 20_000;
export const LAUNCHER_SETTLE = 5; // ~10s behind Base head
export const LAUNCHER_SPAN = 10_000; // default blocks per pass (halves on RPC 400)
export const LAUNCHER_MIN_SPAN = 10;
export const LAUNCHER_MAX_WRITES = 30;

const ZERO = "0x0000000000000000000000000000000000000000";
const POOLS_SLOT = "0x0000000000000000000000000000000000000000000000000000000000000006" as Hex;
const PROBE_PINTO = 100_000_000n; // 100 Pinto (6 dec)

const FACTORY_ABI = parseAbi([
  "event Launched(address indexed coin, address vault, bytes32 indexed id, address indexed launcher, uint8 mode, uint16 feeBps, uint16 creatorBps, uint256 firstBuyWeth, uint256 coinsBought)",
]);

const POOL_ABI = parseAbi([
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
  "function extsload(bytes32 slot) view returns (bytes32)",
]);

const VAULT_EVENTS_ABI = parseAbi([
  "event Converted(uint256 wethIn, uint256 pintoOut, uint256 tip)",
  "event Seeded(address indexed caller, uint256 amount)",
  "event BoughtBack(uint256 pintoIn, uint256 coinsBurned, uint256 tip)",
  "event Redeemed(address indexed holder, address indexed recipient, uint256 coins, uint256 pinto)",
  "event CreatorPayoutChanged(address indexed previous, address indexed next)",
]);

const ERC20_TRANSFER_ABI = parseAbi([
  "event Transfer(address indexed from, address indexed to, uint256 value)",
]);

const READ_ABI = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function imageURI() view returns (string)",
  "function metadataURI() view returns (string)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function siloPinto() view returns (uint256)",
  "function pendingPintoWeth() view returns (uint256)",
  "function yieldPinto() view returns (uint256)",
  "function creatorPayout() view returns (address)",
  "function creatorBps() view returns (uint16)",
  "function coin(bytes32 id) view returns (address vault, uint16 feeBps, uint64 launchedAt, bool coinIsToken0, int56 emaQ, uint64 emaTs)",
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)",
  "function getSwapOut(address, address, uint256) view returns (uint256)",
]);

export const TOPIC_LAUNCHED = keccak256(
  encodePacked(
    ["string"],
    ["Launched(address,address,bytes32,address,uint8,uint16,uint16,uint256,uint256)"],
  ),
);
export const TOPIC_SWAP = keccak256(
  encodePacked(
    ["string"],
    ["Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"],
  ),
);
export const TOPIC_TRANSFER = keccak256(
  encodePacked(["string"], ["Transfer(address,address,uint256)"]),
);

/** Computes the PoolId = keccak256(abi.encode(PoolKey)) for a launcher coin. */
export function computePoolId(coin: Address, hook: Address): { poolId: Hex; coinIsToken0: boolean } {
  const coinLc = coin.toLowerCase();
  const wethLc = BASE_WETH.toLowerCase();
  const coinIsToken0 = coinLc < wethLc;
  const currency0 = (coinIsToken0 ? coin : BASE_WETH) as Address;
  const currency1 = (coinIsToken0 ? BASE_WETH : coin) as Address;
  const encoded = encodeAbiParameters(
    parseAbiParameters("address, address, uint24, int24, address"),
    [currency0, currency1, LAUNCHER_LP_FEE, LAUNCHER_TICK_SPACING, hook],
  );
  return { poolId: keccak256(encoded), coinIsToken0 };
}

/** Storage slot of slot0 in Uniswap v4 PoolManager (`StateLibrary.POOLS_SLOT = 6`). */
export function poolSlot(poolId: Hex): Hex {
  return keccak256(encodePacked(["bytes32", "bytes32"], [poolId, POOLS_SLOT]));
}

/** Unpacks Uniswap v4 slot0 word into sqrtPriceX96 (low 160 bits) and signed int24 tick (next 24 bits). */
export function decodeSlot0(word: Hex): { sqrtPriceX96: bigint; tick: number } {
  const v = BigInt(word);
  const sqrtPriceX96 = v & ((1n << 160n) - 1n);
  const rawTick = Number((v >> 160n) & 0xffffffn);
  const tick = rawTick >= 0x800000 ? rawTick - 0x1000000 : rawTick;
  return { sqrtPriceX96, tick };
}

/** Converts Uniswap v4 sqrtPriceX96 to WETH per 1 coin (both 18 decimals). */
export function sqrtPriceToWethPerCoin(sqrtPriceX96: bigint, coinIsToken0: boolean): number {
  if (sqrtPriceX96 === 0n) return 0;
  const q96 = 2 ** 96;
  const r = Number(sqrtPriceX96) / q96;
  const ratio = r * r; // token1 / token0
  if (!Number.isFinite(ratio) || ratio <= 0) return 0;
  return coinIsToken0 ? ratio : 1 / ratio;
}

/** Converts WETH/USDC v3 pool sqrtPriceX96 (token0=WETH 18dec, token1=USDC 6dec) to USD per WETH. */
export function wethUsdcSqrtPriceToUsd(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 === 0n) return 0;
  const r = Number(sqrtPriceX96) / 2 ** 96;
  const usd = r * r * 1e12;
  return Number.isFinite(usd) && usd > 0 ? usd : 0;
}

export type GetLogsFilter = {
  address?: string | string[];
  topics?: (string | string[] | null)[];
  fromBlock: number;
  toBlock: number;
};

export type LauncherRpc = {
  getBlockNumber: () => Promise<number>;
  getLogs: (filter: GetLogsFilter) => Promise<RawLog[]>;
  multicall: Multicall;
  multicallOptional: (
    contracts: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }[],
  ) => Promise<{ status: "success" | "failure"; result?: unknown }[]>;
};

/** Queries getLogs, automatically halving the block range if the RPC rejects the span (e.g. Alchemy 400). */
async function getLogsBounded(
  getLogs: LauncherRpc["getLogs"],
  filter: Omit<GetLogsFilter, "fromBlock" | "toBlock">,
  from: number,
  to: number,
): Promise<{ logs: RawLog[]; endBlock: number }> {
  let hi = to;
  while (true) {
    try {
      const logs = await getLogs({ ...filter, fromBlock: from, toBlock: hi });
      return { logs, endBlock: hi };
    } catch (e) {
      const span = hi - from + 1;
      if (span <= LAUNCHER_MIN_SPAN) throw e;
      hi = from + Math.max(LAUNCHER_MIN_SPAN, Math.floor(span / 2)) - 1;
    }
  }
}

export type CoinRow = {
  factory: string;
  coin: string;
  vault: string;
  pool_id: string;
  launcher: string;
  creator_payout: string;
  mode: number;
  fee_bps: number;
  creator_bps: number;
  name: string;
  symbol: string;
  image_uri: string;
  metadata_uri: string;
  website_url: string;
  twitter_url: string;
  description: string;
  coin_is_token0: number;
  launched_block: number;
  launched_at: number;
  first_buy_weth: string;
  hidden: number;
  hidden_reason: string | null;
  price_weth: number;
  silo_pinto: string;
  silo_pinto_num: number;
  yield_pinto: string;
  pending_weth: string;
  unsplit_weth: string;
  total_supply: string;
  vol_24h_weth: number;
  vol_all_weth: number;
  trades_24h: number;
  trades_all: number;
  last_swap_at: number;
  creator_paid_weth: string;
};

export type DecodedLaunched = {
  coin: string;
  vault: string;
  poolId: string;
  launcher: string;
  mode: number;
  feeBps: number;
  creatorBps: number;
  firstBuyWeth: string;
  coinsBought: string;
  block: number;
  t: number;
};

export type DecodedSwap = {
  poolId: string;
  block: number;
  logIdx: number;
  tx: string;
  t: number;
  isBuy: number;
  wethWei: string;
  coinWei: string;
  wethNum: number;
  sqrtPriceX96: string;
  tick: number;
  priceWeth: number;
};

export type DecodedVaultEvent = {
  vault: string;
  block: number;
  logIdx: number;
  tx: string;
  t: number;
  kind: "convert" | "seed" | "buyback" | "redeem" | "payout_changed";
  actor: string | null;
  amountA: string;
  amountB: string;
  tip: string;
};

export function decodeLaunchedLogs(logs: RawLog[], factory: string): DecodedLaunched[] {
  const f = factory.toLowerCase();
  const out: DecodedLaunched[] = [];
  for (const l of logs) {
    if (l.removed || l.address.toLowerCase() !== f) continue;
    try {
      const ev = decodeEventLog({ abi: FACTORY_ABI, topics: l.topics as [Hex, ...Hex[]], data: l.data as Hex });
      if (ev.eventName !== "Launched") continue;
      if (!l.blockTimestamp) throw new Error(`Launched log missing blockTimestamp (tx ${l.transactionHash})`);
      out.push({
        coin: ev.args.coin.toLowerCase(),
        vault: ev.args.vault.toLowerCase(),
        poolId: ev.args.id.toLowerCase(),
        launcher: ev.args.launcher.toLowerCase(),
        mode: Number(ev.args.mode),
        feeBps: Number(ev.args.feeBps),
        creatorBps: Number(ev.args.creatorBps),
        firstBuyWeth: String(ev.args.firstBuyWeth),
        coinsBought: String(ev.args.coinsBought),
        block: Number(l.blockNumber),
        t: Number(l.blockTimestamp),
      });
    } catch (e) {
      if (e instanceof Error && e.message.includes("blockTimestamp")) throw e;
    }
  }
  return out;
}

export function decodeSwapLogs(logs: RawLog[], coinIsToken0ByPool: Map<string, boolean>): DecodedSwap[] {
  const pm = BASE_POOL_MANAGER.toLowerCase();
  const out: DecodedSwap[] = [];
  for (const l of logs) {
    if (l.removed || l.address.toLowerCase() !== pm) continue;
    try {
      const ev = decodeEventLog({ abi: POOL_ABI, topics: l.topics as [Hex, ...Hex[]], data: l.data as Hex });
      if (ev.eventName !== "Swap") continue;
      const poolId = ev.args.id.toLowerCase();
      const coinIsToken0 = coinIsToken0ByPool.get(poolId);
      if (coinIsToken0 === undefined) continue;
      if (!l.blockTimestamp) throw new Error(`Swap log missing blockTimestamp (tx ${l.transactionHash})`);
      const wethDelta = coinIsToken0 ? ev.args.amount1 : ev.args.amount0;
      const coinDelta = coinIsToken0 ? ev.args.amount0 : ev.args.amount1;
      const isBuy = wethDelta < 0n ? 1 : 0;
      const wethAbs = wethDelta < 0n ? -wethDelta : wethDelta;
      const coinAbs = coinDelta < 0n ? -coinDelta : coinDelta;
      const sqrt = ev.args.sqrtPriceX96;
      out.push({
        poolId,
        block: Number(l.blockNumber),
        logIdx: Number(l.logIndex),
        tx: l.transactionHash.toLowerCase(),
        t: Number(l.blockTimestamp),
        isBuy,
        wethWei: String(wethAbs),
        coinWei: String(coinAbs),
        wethNum: Number(wethAbs) / 1e18,
        sqrtPriceX96: String(sqrt),
        tick: Number(ev.args.tick),
        priceWeth: sqrtPriceToWethPerCoin(sqrt, coinIsToken0),
      });
    } catch (e) {
      if (e instanceof Error && e.message.includes("blockTimestamp")) throw e;
    }
  }
  return out;
}

export function decodeVaultLogs(logs: RawLog[], knownVaults: Set<string>): DecodedVaultEvent[] {
  const out: DecodedVaultEvent[] = [];
  for (const l of logs) {
    const addr = l.address.toLowerCase();
    if (l.removed || !knownVaults.has(addr)) continue;
    try {
      const ev = decodeEventLog({ abi: VAULT_EVENTS_ABI, topics: l.topics as [Hex, ...Hex[]], data: l.data as Hex });
      if (!l.blockTimestamp) throw new Error(`Vault log missing blockTimestamp (tx ${l.transactionHash})`);
      const base = {
        vault: addr,
        block: Number(l.blockNumber),
        logIdx: Number(l.logIndex),
        tx: l.transactionHash.toLowerCase(),
        t: Number(l.blockTimestamp),
      };
      if (ev.eventName === "Converted") {
        out.push({ ...base, kind: "convert", actor: null, amountA: String(ev.args.wethIn), amountB: String(ev.args.pintoOut), tip: String(ev.args.tip) });
      } else if (ev.eventName === "Seeded") {
        out.push({ ...base, kind: "seed", actor: ev.args.caller.toLowerCase(), amountA: String(ev.args.amount), amountB: "0", tip: "0" });
      } else if (ev.eventName === "BoughtBack") {
        out.push({ ...base, kind: "buyback", actor: null, amountA: String(ev.args.pintoIn), amountB: String(ev.args.coinsBurned), tip: String(ev.args.tip) });
      } else if (ev.eventName === "Redeemed") {
        out.push({ ...base, kind: "redeem", actor: ev.args.holder.toLowerCase(), amountA: String(ev.args.coins), amountB: String(ev.args.pinto), tip: "0" });
      } else if (ev.eventName === "CreatorPayoutChanged") {
        out.push({ ...base, kind: "payout_changed", actor: ev.args.next.toLowerCase(), amountA: "0", amountB: "0", tip: "0" });
      }
    } catch (e) {
      if (e instanceof Error && e.message.includes("blockTimestamp")) throw e;
    }
  }
  return out;
}

/** Attributes WETH Transfer(from=vault, to=creatorPayout) to creator earnings while excluding convert() tips. */
export function computeCreatorPayouts(
  wethLogs: RawLog[],
  vaultEvents: DecodedVaultEvent[],
  initialPayoutByVault: Map<string, string>,
): { deltaByVault: Map<string, bigint>; latestPayoutByVault: Map<string, string> } {
  // Sort vault payout changes and WETH transfers in chronological block/log order.
  const latestPayoutByVault = new Map(initialPayoutByVault);
  // Map of `${tx}:${vault}` -> tip amounts paid by convert() in that tx, so if creator == keeper we don't double-count tip.
  const convertTips = new Map<string, bigint[]>();
  for (const ve of vaultEvents) {
    if (ve.kind === "convert" && BigInt(ve.tip) > 0n) {
      const k = `${ve.tx}:${ve.vault}`;
      const arr = convertTips.get(k) ?? [];
      arr.push(BigInt(ve.tip));
      convertTips.set(k, arr);
    }
  }

  type Step =
    | { kind: "payout"; block: number; logIdx: number; vault: string; next: string }
    | { kind: "weth"; block: number; logIdx: number; tx: string; vault: string; to: string; value: bigint };

  const steps: Step[] = [];
  for (const ve of vaultEvents) {
    if (ve.kind === "payout_changed" && ve.actor) {
      steps.push({ kind: "payout", block: ve.block, logIdx: ve.logIdx, vault: ve.vault, next: ve.actor });
    }
  }
  const wethAddr = BASE_WETH.toLowerCase();
  for (const l of wethLogs) {
    if (l.removed || l.address.toLowerCase() !== wethAddr) continue;
    try {
      const ev = decodeEventLog({ abi: ERC20_TRANSFER_ABI, topics: l.topics as [Hex, ...Hex[]], data: l.data as Hex });
      if (ev.eventName !== "Transfer") continue;
      const from = ev.args.from.toLowerCase();
      if (!latestPayoutByVault.has(from)) continue;
      steps.push({
        kind: "weth",
        block: Number(l.blockNumber),
        logIdx: Number(l.logIndex),
        tx: l.transactionHash.toLowerCase(),
        vault: from,
        to: ev.args.to.toLowerCase(),
        value: ev.args.value,
      });
    } catch {
      // ignore unrelated log
    }
  }

  steps.sort((a, b) => a.block - b.block || a.logIdx - b.logIdx);
  const deltaByVault = new Map<string, bigint>();
  for (const s of steps) {
    if (s.kind === "payout") {
      latestPayoutByVault.set(s.vault, s.next);
      continue;
    }
    const payout = latestPayoutByVault.get(s.vault);
    if (!payout || s.to !== payout) continue;
    // Check if this transfer matches a convert() tip in the same tx.
    const tips = convertTips.get(`${s.tx}:${s.vault}`);
    if (tips) {
      const idx = tips.indexOf(s.value);
      if (idx !== -1) {
        tips.splice(idx, 1);
        continue;
      }
    }
    deltaByVault.set(s.vault, (deltaByVault.get(s.vault) ?? 0n) + s.value);
  }
  return { deltaByVault, latestPayoutByVault };
}

/** Reads WETH/USD (v3 0.05% pool) and Pinto/USD (USDC Stable2 well) in one multicall. */
export async function readRefPrices(multicall: Multicall): Promise<{ wethUsd: number; pintoUsd: number }> {
  const res = await multicall([
    { address: BASE_WETH_USDC_POOL, abi: READ_ABI, functionName: "slot0" },
    { address: BASE_USDC_WELL, abi: READ_ABI, functionName: "getSwapOut", args: [BASE_PINTO, BASE_USDC, PROBE_PINTO] },
  ]);
  const slot0 = res[0] as readonly [bigint, ...unknown[]];
  const usdcOut = res[1] as bigint;
  return {
    wethUsd: wethUsdcSqrtPriceToUsd(slot0[0]),
    pintoUsd: Number(usdcOut) / Number(PROBE_PINTO),
  };
}

/** Ensures the factory has a row in launcher_state. */
export async function ensureLauncherState(db: D1Like, cfg: LauncherConfig): Promise<{ cursor_block: number; last_refresh_ms: number; weth_usd: number; pinto_usd: number }> {
  const f = cfg.factory.toLowerCase();
  const row = await db
    .prepare("SELECT cursor_block, last_refresh_ms, weth_usd, pinto_usd FROM launcher_state WHERE factory = ?")
    .bind(f)
    .first<{ cursor_block: number; last_refresh_ms: number; weth_usd: number; pinto_usd: number }>();
  if (row) return row;
  const start = Math.max(0, cfg.deployBlock - 1);
  await db
    .prepare("INSERT OR IGNORE INTO launcher_state (factory, cursor_block, last_refresh_ms, weth_usd, pinto_usd) VALUES (?, ?, 0, 0, 0)")
    .bind(f, start)
    .run();
  return { cursor_block: start, last_refresh_ms: 0, weth_usd: 0, pinto_usd: 0 };
}

/** Extracts a hosted /api/launcher/meta/<sha256>.json key if the URI points at our metadata store. */
function metaKeyFromUri(uri: string): string | null {
  const m = /\/api\/launcher\/meta\/([0-9a-f]{64}\.json)$/.exec(uri.trim());
  return m ? m[1] : null;
}

/** Indexes up to LAUNCHER_SPAN blocks of factory/pool/vault events and refreshes live coin metrics. */
export async function indexLauncher(
  db: D1Like,
  rpc: LauncherRpc,
  cfg: LauncherConfig,
  nowMs: number,
  refreshAllMetrics = false,
  bucket?: R2BucketLike,
): Promise<{ from: number; to: number; newCoins: number; swaps: number; vaultEvents: number }> {
  const f = cfg.factory.toLowerCase();
  const state = await ensureLauncherState(db, cfg);
  const head = await rpc.getBlockNumber();
  const targetTo = Math.min(state.cursor_block + LAUNCHER_SPAN, head - LAUNCHER_SETTLE);

  // Always refresh WETH/USD + Pinto/USD reference prices.
  let { weth_usd: wethUsd, pinto_usd: pintoUsd } = state;
  try {
    const ref = await readRefPrices(rpc.multicall);
    if (ref.wethUsd > 0) wethUsd = ref.wethUsd;
    if (ref.pintoUsd > 0) pintoUsd = ref.pintoUsd;
  } catch {
    // keep previous reference prices on transient RPC hiccup
  }

  // Load existing coins for this factory.
  const existing = (
    await db.prepare("SELECT * FROM launcher_coins WHERE factory = ?").bind(f).all<CoinRow>()
  ).results;

  const coinByPool = new Map<string, CoinRow>();
  const coinByVault = new Map<string, CoinRow>();
  const coinIsToken0ByPool = new Map<string, boolean>();
  const payoutByVault = new Map<string, string>();
  const knownVaults = new Set<string>();
  for (const c of existing) {
    coinByPool.set(c.pool_id, c);
    coinByVault.set(c.vault, c);
    coinIsToken0ByPool.set(c.pool_id, c.coin_is_token0 === 1);
    payoutByVault.set(c.vault, c.creator_payout);
    knownVaults.add(c.vault);
  }

  let from = state.cursor_block + 1;
  let to = targetTo;
  let newCoins: DecodedLaunched[] = [];
  let swaps: DecodedSwap[] = [];
  let vaultEvents: DecodedVaultEvent[] = [];
  let wethLogs: RawLog[] = [];

  if (to >= from) {
    // 1. Scan Launched events from factory (shrinks `to` if RPC rejects span).
    const launchedRes = await getLogsBounded(
      rpc.getLogs,
      { address: f, topics: [TOPIC_LAUNCHED] },
      from,
      to,
    );
    to = launchedRes.endBlock;
    newCoins = decodeLaunchedLogs(launchedRes.logs, f);

    // Fetch static metadata + hook info for any newly launched coin.
    const newMeta = new Map<
      string,
      {
        name: string;
        symbol: string;
        imageUri: string;
        metadataUri: string;
        websiteUrl: string;
        twitterUrl: string;
        description: string;
        creatorPayout: string;
        coinIsToken0: boolean;
      }
    >();
    if (newCoins.length > 0) {
      const calls = newCoins.flatMap((nc) => [
        { address: nc.coin as Address, abi: READ_ABI, functionName: "name" },
        { address: nc.coin as Address, abi: READ_ABI, functionName: "symbol" },
        { address: nc.coin as Address, abi: READ_ABI, functionName: "imageURI" },
        { address: nc.vault as Address, abi: READ_ABI, functionName: "creatorPayout" },
        { address: cfg.hook, abi: READ_ABI, functionName: "coin", args: [nc.poolId as Hex] },
      ]);
      const vals = await rpc.multicall(calls);
      // Optional metadataURI() call — absent on the TEST factory, present on the real factory.
      const metaCalls = newCoins.map((nc) => ({ address: nc.coin as Address, abi: READ_ABI, functionName: "metadataURI" }));
      const metaVals = await rpc.multicallOptional(metaCalls);

      for (let i = 0; i < newCoins.length; i++) {
        const nc = newCoins[i];
        const base = i * 5;
        const hookCoin = vals[base + 4] as readonly [Address, number, bigint, boolean, bigint, bigint];
        const coinIsToken0 = Boolean(hookCoin[3]);
        const creatorPayout = String(vals[base + 3]).toLowerCase();
        const metadataUri = metaVals[i]?.status === "success" ? String(metaVals[i].result ?? "") : "";
        let websiteUrl = "";
        let twitterUrl = "";
        let description = "";
        const mKey = metadataUri ? metaKeyFromUri(metadataUri) : null;
        if (mKey && bucket) {
          const doc = await readStoredMeta(mKey, bucket);
          if (doc) {
            websiteUrl = doc.website || doc.external_link || doc.links?.website || "";
            twitterUrl = doc.links?.twitter || "";
            description = doc.description || "";
          }
        }
        // If no on-chain metadataURI (e.g. TEST factory), pick up any write-once attachment saved before settle.
        let finalMetaUri = metadataUri;
        if (!finalMetaUri) {
          const pre = await db
            .prepare("SELECT metadata_uri, website_url, twitter_url, description FROM launcher_coin_meta WHERE factory = ? AND coin = ?")
            .bind(f, nc.coin)
            .first<{ metadata_uri: string; website_url: string; twitter_url: string; description: string }>();
          if (pre) {
            finalMetaUri = pre.metadata_uri;
            websiteUrl = pre.website_url;
            twitterUrl = pre.twitter_url;
            description = pre.description;
          }
        }
        newMeta.set(nc.coin, {
          name: String(vals[base] ?? ""),
          symbol: String(vals[base + 1] ?? ""),
          imageUri: String(vals[base + 2] ?? ""),
          metadataUri: finalMetaUri,
          websiteUrl,
          twitterUrl,
          description,
          creatorPayout,
          coinIsToken0,
        });
        coinIsToken0ByPool.set(nc.poolId, coinIsToken0);
        payoutByVault.set(nc.vault, creatorPayout);
        knownVaults.add(nc.vault);
      }
    }

    // 2. Scan PoolManager.Swap logs filtered strictly by our poolIds (chunks of 50).
    const allPoolIds = [...coinIsToken0ByPool.keys()];
    if (allPoolIds.length > 0) {
      const rawSwaps: RawLog[] = [];
      for (let i = 0; i < allPoolIds.length; i += 50) {
        const chunk = allPoolIds.slice(i, i + 50);
        const res = await getLogsBounded(
          rpc.getLogs,
          { address: BASE_POOL_MANAGER.toLowerCase(), topics: [TOPIC_SWAP, chunk] },
          from,
          to,
        );
        // If a chunk forced an earlier endBlock, trim `to` for consistency.
        if (res.endBlock < to) to = res.endBlock;
        rawSwaps.push(...res.logs);
      }
      swaps = decodeSwapLogs(
        rawSwaps.filter((l) => Number(l.blockNumber) <= to),
        coinIsToken0ByPool,
      );
    }

    // 3. Scan vault events + WETH transfers out of vaults (chunks of 50 vaults).
    const allVaults = [...knownVaults];
    if (allVaults.length > 0) {
      const rawVault: RawLog[] = [];
      const rawWeth: RawLog[] = [];
      for (let i = 0; i < allVaults.length; i += 50) {
        const chunk = allVaults.slice(i, i + 50);
        const vr = await getLogsBounded(rpc.getLogs, { address: chunk }, from, to);
        if (vr.endBlock < to) to = vr.endBlock;
        rawVault.push(...vr.logs);

        const paddedFrom = chunk.map((v) => pad(v as Hex, { size: 32 }).toLowerCase());
        const wr = await getLogsBounded(
          rpc.getLogs,
          { address: BASE_WETH.toLowerCase(), topics: [TOPIC_TRANSFER, paddedFrom] },
          from,
          to,
        );
        if (wr.endBlock < to) to = wr.endBlock;
        rawWeth.push(...wr.logs);
      }
      vaultEvents = decodeVaultLogs(
        rawVault.filter((l) => Number(l.blockNumber) <= to),
        knownVaults,
      );
      wethLogs = rawWeth.filter((l) => Number(l.blockNumber) <= to);
    }

    // Filter newCoins to <= to in case endBlock shrank.
    newCoins = newCoins.filter((c) => c.block <= to);

    // Cut at a block boundary if total event writes exceed LAUNCHER_MAX_WRITES.
    const allBlocks = [
      ...newCoins.map((c) => c.block),
      ...swaps.map((s) => s.block),
      ...vaultEvents.map((v) => v.block),
    ].sort((a, b) => a - b);
    const totalEvents = newCoins.length + swaps.length + vaultEvents.length;
    if (totalEvents > LAUNCHER_MAX_WRITES && allBlocks.length > LAUNCHER_MAX_WRITES) {
      const cutBlock = allBlocks[LAUNCHER_MAX_WRITES - 1];
      // Include all events up to cutBlock - 1 (or cutBlock if first block already > max).
      const firstBlock = allBlocks[0];
      const keepThrough = cutBlock > firstBlock ? cutBlock - 1 : firstBlock;
      to = keepThrough;
      newCoins = newCoins.filter((c) => c.block <= to);
      swaps = swaps.filter((s) => s.block <= to);
      vaultEvents = vaultEvents.filter((v) => v.block <= to);
      wethLogs = wethLogs.filter((l) => Number(l.blockNumber) <= to);
    }

    const { deltaByVault, latestPayoutByVault } = computeCreatorPayouts(wethLogs, vaultEvents, payoutByVault);

    // Build atomic D1 batch: range guard + inserts + cursor update.
    const stmts = [
      db.prepare("INSERT INTO launcher_ranges (factory, from_block, to_block) VALUES (?, ?, ?)").bind(f, from, to),
    ];

    for (const nc of newCoins) {
      const meta = newMeta.get(nc.coin)!;
      stmts.push(
        db
          .prepare(
            `INSERT OR IGNORE INTO launcher_coins
            (factory, coin, vault, pool_id, launcher, creator_payout, mode, fee_bps, creator_bps, name, symbol, image_uri, metadata_uri, website_url, twitter_url, description, coin_is_token0, launched_block, launched_at, first_buy_weth)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(
            f, nc.coin, nc.vault, nc.poolId, nc.launcher, meta.creatorPayout,
            nc.mode, nc.feeBps, nc.creatorBps, meta.name, meta.symbol, meta.imageUri,
            meta.metadataUri, meta.websiteUrl, meta.twitterUrl, meta.description,
            meta.coinIsToken0 ? 1 : 0, nc.block, nc.t, nc.firstBuyWeth,
          ),
      );
    }

    for (const sw of swaps) {
      stmts.push(
        db
          .prepare(
            `INSERT OR IGNORE INTO launcher_swaps
            (factory, pool_id, block, log_idx, tx, t, is_buy, weth_wei, coin_wei, weth_num, sqrt_price_x96, tick, price_weth)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(
            f, sw.poolId, sw.block, sw.logIdx, sw.tx, sw.t, sw.isBuy,
            sw.wethWei, sw.coinWei, sw.wethNum, sw.sqrtPriceX96, sw.tick, sw.priceWeth,
          ),
      );
    }

    for (const ve of vaultEvents) {
      stmts.push(
        db
          .prepare(
            `INSERT OR IGNORE INTO launcher_vault_events
            (factory, vault, block, log_idx, tx, t, kind, actor, amount_a, amount_b, tip)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(f, ve.vault, ve.block, ve.logIdx, ve.tx, ve.t, ve.kind, ve.actor, ve.amountA, ve.amountB, ve.tip),
      );
    }

    // Update creator_paid_weth & creator_payout for vaults that changed.
    const touchedPayoutVaults = new Set([...deltaByVault.keys()]);
    for (const ve of vaultEvents) if (ve.kind === "payout_changed") touchedPayoutVaults.add(ve.vault);
    for (const v of touchedPayoutVaults) {
      const prevPaid = BigInt(coinByVault.get(v)?.creator_paid_weth ?? "0");
      const nextPaid = prevPaid + (deltaByVault.get(v) ?? 0n);
      const nextPayout = latestPayoutByVault.get(v) ?? coinByVault.get(v)?.creator_payout ?? ZERO;
      stmts.push(
        db
          .prepare("UPDATE launcher_coins SET creator_paid_weth = ?, creator_payout = ? WHERE factory = ? AND vault = ?")
          .bind(String(nextPaid), nextPayout, f, v),
      );
    }

    stmts.push(
      db
        .prepare("UPDATE launcher_state SET cursor_block = ?, last_refresh_ms = ?, weth_usd = ?, pinto_usd = ? WHERE factory = ?")
        .bind(to, nowMs, wethUsd, pintoUsd, f),
    );

    await db.batch(stmts);
  } else {
    await db
      .prepare("UPDATE launcher_state SET last_refresh_ms = ?, weth_usd = ?, pinto_usd = ? WHERE factory = ?")
      .bind(nowMs, wethUsd, pintoUsd, f)
      .run();
  }

  // 4. Refresh live on-chain metrics + 24h swap rollups for touched coins (or all coins on cron/initial).
  const allCoinsNow = (
    await db.prepare("SELECT * FROM launcher_coins WHERE factory = ?").bind(f).all<CoinRow>()
  ).results;
  const touchedPools = new Set(swaps.map((s) => s.poolId));
  const touchedVaults = new Set(vaultEvents.map((v) => v.vault));
  const newCoinSet = new Set(newCoins.map((c) => c.coin));

  const toRefresh = refreshAllMetrics
    ? allCoinsNow
    : allCoinsNow.filter(
        (c) =>
          newCoinSet.has(c.coin) ||
          touchedPools.has(c.pool_id) ||
          touchedVaults.has(c.vault) ||
          c.price_weth === 0,
      );

  if (toRefresh.length > 0) {
    await refreshCoinMetrics(db, rpc, f, toRefresh, Math.floor(nowMs / 1000));
  }

  return {
    from,
    to: to >= from ? to : state.cursor_block,
    newCoins: newCoins.length,
    swaps: swaps.length,
    vaultEvents: vaultEvents.length,
  };
}

/** Batch-refreshes slot0 price, Silo Pinto, pending/unsplit WETH, totalSupply, yieldPinto, and 24h swap stats. */
export async function refreshCoinMetrics(
  db: D1Like,
  rpc: LauncherRpc,
  factory: string,
  coins: CoinRow[],
  nowSec: number,
): Promise<void> {
  const cutoff24h = nowSec - 86_400;
  // Batch 10 coins per multicall to stay well under payload limits.
  for (let i = 0; i < coins.length; i += 10) {
    const batch = coins.slice(i, i + 10);
    const calls = batch.flatMap((c) => [
      { address: BASE_POOL_MANAGER, abi: POOL_ABI, functionName: "extsload", args: [poolSlot(c.pool_id as Hex)] },
      { address: c.vault as Address, abi: READ_ABI, functionName: "siloPinto" },
      { address: c.vault as Address, abi: READ_ABI, functionName: "pendingPintoWeth" },
      { address: BASE_WETH, abi: READ_ABI, functionName: "balanceOf", args: [c.vault as Address] },
      { address: c.coin as Address, abi: READ_ABI, functionName: "totalSupply" },
      { address: c.vault as Address, abi: READ_ABI, functionName: "yieldPinto" }, // succeeds for Burn, reverts for Redeem
    ]);
    const results = await rpc.multicallOptional(calls);
    const stmts = [];
    for (let j = 0; j < batch.length; j++) {
      const c = batch[j];
      const base = j * 6;
      const slotWord = results[base].status === "success" ? (results[base].result as Hex) : null;
      const priceWeth = slotWord
        ? sqrtPriceToWethPerCoin(decodeSlot0(slotWord).sqrtPriceX96, c.coin_is_token0 === 1)
        : c.price_weth;
      const siloPinto = results[base + 1].status === "success" ? (results[base + 1].result as bigint) : BigInt(c.silo_pinto);
      const pendingWeth = results[base + 2].status === "success" ? (results[base + 2].result as bigint) : BigInt(c.pending_weth);
      const vaultWeth = results[base + 3].status === "success" ? (results[base + 3].result as bigint) : pendingWeth;
      const unsplitWeth = vaultWeth > pendingWeth ? vaultWeth - pendingWeth : 0n;
      const totalSupply = results[base + 4].status === "success" ? (results[base + 4].result as bigint) : BigInt(c.total_supply);
      const yieldPinto = results[base + 5].status === "success" ? (results[base + 5].result as bigint) : 0n;

      const agg = await db
        .prepare(
          `SELECT
            COALESCE(SUM(CASE WHEN t >= ? THEN weth_num ELSE 0 END), 0) AS vol24,
            COALESCE(SUM(weth_num), 0) AS volAll,
            COALESCE(SUM(CASE WHEN t >= ? THEN 1 ELSE 0 END), 0) AS trades24,
            COUNT(*) AS tradesAll,
            COALESCE(MAX(t), 0) AS lastAt
          FROM launcher_swaps WHERE factory = ? AND pool_id = ?`,
        )
        .bind(cutoff24h, cutoff24h, factory, c.pool_id)
        .first<{ vol24: number; volAll: number; trades24: number; tradesAll: number; lastAt: number }>();

      stmts.push(
        db
          .prepare(
            `UPDATE launcher_coins SET
              price_weth = ?, silo_pinto = ?, silo_pinto_num = ?, yield_pinto = ?,
              pending_weth = ?, unsplit_weth = ?, total_supply = ?,
              vol_24h_weth = ?, vol_all_weth = ?, trades_24h = ?, trades_all = ?, last_swap_at = ?
            WHERE factory = ? AND coin = ?`,
          )
          .bind(
            priceWeth,
            String(siloPinto),
            Number(siloPinto) / 1e6,
            String(yieldPinto),
            String(pendingWeth),
            String(unsplitWeth),
            String(totalSupply),
            agg?.vol24 ?? 0,
            agg?.volAll ?? 0,
            agg?.trades24 ?? 0,
            agg?.tradesAll ?? 0,
            agg?.lastAt ?? 0,
            factory,
            c.coin,
          ),
      );
    }
    if (stmts.length > 0) await db.batch(stmts);
  }
}

/** Conditional-UPDATE lock: at most one request per LAUNCHER_FRESH_MS runs indexLauncher. */
export async function indexLauncherIfDue(
  db: D1Like,
  rpc: LauncherRpc | null,
  cfg: LauncherConfig,
  nowMs: number,
  bucket?: R2BucketLike,
): Promise<void> {
  if (!rpc) return;
  const f = cfg.factory.toLowerCase();
  await ensureLauncherState(db, cfg);
  const claim = await db
    .prepare("UPDATE launcher_state SET last_refresh_ms = ? WHERE factory = ? AND last_refresh_ms <= ?")
    .bind(nowMs, f, nowMs - LAUNCHER_FRESH_MS)
    .run();
  if (claim.meta.changes === 0) return;
  try {
    await indexLauncher(db, rpc, cfg, nowMs, false, bucket);
  } catch {
    // Fail-closed: callers still serve cached D1 rows.
  }
}

/** On-chain fallback for a just-launched coin not yet settled in D1 (prevents 404 right after launch). */
export async function readSingleCoinLive(
  rpc: LauncherRpc,
  cfg: LauncherConfig,
  coinAddr: Address,
  bucket?: R2BucketLike,
): Promise<CoinRow | null> {
  const { poolId, coinIsToken0 } = computePoolId(coinAddr, cfg.hook);
  const hookRes = await rpc.multicallOptional([
    { address: cfg.hook, abi: READ_ABI, functionName: "coin", args: [poolId] },
  ]);
  if (hookRes[0].status !== "success") return null;
  const [vaultRaw, feeBps, launchedAt, isToken0] = hookRes[0].result as readonly [Address, number, bigint, boolean, bigint, bigint];
  const vault = vaultRaw.toLowerCase();
  if (vault === ZERO) return null;

  const res = await rpc.multicallOptional([
    { address: coinAddr, abi: READ_ABI, functionName: "name" },
    { address: coinAddr, abi: READ_ABI, functionName: "symbol" },
    { address: coinAddr, abi: READ_ABI, functionName: "imageURI" },
    { address: coinAddr, abi: READ_ABI, functionName: "totalSupply" },
    { address: vault as Address, abi: READ_ABI, functionName: "creatorPayout" },
    { address: vault as Address, abi: READ_ABI, functionName: "creatorBps" },
    { address: vault as Address, abi: READ_ABI, functionName: "siloPinto" },
    { address: vault as Address, abi: READ_ABI, functionName: "pendingPintoWeth" },
    { address: BASE_WETH, abi: READ_ABI, functionName: "balanceOf", args: [vault as Address] },
    { address: BASE_POOL_MANAGER, abi: POOL_ABI, functionName: "extsload", args: [poolSlot(poolId)] },
    { address: vault as Address, abi: READ_ABI, functionName: "yieldPinto" },
    { address: coinAddr, abi: READ_ABI, functionName: "metadataURI" },
  ]);

  const siloPinto = res[6].status === "success" ? (res[6].result as bigint) : 0n;
  const pendingWeth = res[7].status === "success" ? (res[7].result as bigint) : 0n;
  const vaultWeth = res[8].status === "success" ? (res[8].result as bigint) : 0n;
  const unsplitWeth = vaultWeth > pendingWeth ? vaultWeth - pendingWeth : 0n;
  const slotWord = res[9].status === "success" ? (res[9].result as Hex) : null;
  const isBurn = res[10].status === "success";
  const yieldPinto = isBurn ? (res[10].result as bigint) : 0n;
  const metadataUri = res[11]?.status === "success" ? String(res[11].result ?? "") : "";
  let websiteUrl = "";
  let twitterUrl = "";
  let description = "";
  const mKey = metadataUri ? metaKeyFromUri(metadataUri) : null;
  if (mKey && bucket) {
    const doc = await readStoredMeta(mKey, bucket);
    if (doc) {
      websiteUrl = doc.website || doc.external_link || doc.links?.website || "";
      twitterUrl = doc.links?.twitter || "";
      description = doc.description || "";
    }
  }

  return {
    factory: cfg.factory.toLowerCase(),
    coin: coinAddr.toLowerCase(),
    vault,
    pool_id: poolId.toLowerCase(),
    launcher: ZERO,
    creator_payout: res[4].status === "success" ? String(res[4].result).toLowerCase() : ZERO,
    mode: isBurn ? 1 : 0,
    fee_bps: Number(feeBps),
    creator_bps: res[5].status === "success" ? Number(res[5].result) : 0,
    name: res[0].status === "success" ? String(res[0].result) : "",
    symbol: res[1].status === "success" ? String(res[1].result) : "",
    image_uri: res[2].status === "success" ? String(res[2].result) : "",
    metadata_uri: metadataUri,
    website_url: websiteUrl,
    twitter_url: twitterUrl,
    description,
    coin_is_token0: (isToken0 ?? coinIsToken0) ? 1 : 0,
    launched_block: 0,
    launched_at: Number(launchedAt),
    first_buy_weth: "0",
    hidden: 0,
    hidden_reason: null,
    price_weth: slotWord ? sqrtPriceToWethPerCoin(decodeSlot0(slotWord).sqrtPriceX96, Boolean(isToken0)) : 0,
    silo_pinto: String(siloPinto),
    silo_pinto_num: Number(siloPinto) / 1e6,
    yield_pinto: String(yieldPinto),
    pending_weth: String(pendingWeth),
    unsplit_weth: String(unsplitWeth),
    total_supply: res[3].status === "success" ? String(res[3].result) : "1000000000000000000000000000",
    vol_24h_weth: 0,
    vol_all_weth: 0,
    trades_24h: 0,
    trades_all: 0,
    last_swap_at: 0,
    creator_paid_weth: "0",
  };
}
