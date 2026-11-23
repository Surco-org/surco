// Cloudflare Worker entrypoint for Surco (surcofi.com):
// serves /api/chirp*, /api/launcher*, /api/0x/*, and read-only /api/rpc.
// Static assets are served by the Cloudflare Assets binding for all non-/api/* paths.
import { createPublicClient, fallback, http } from "viem";
import { handleRpcProxy } from "./rpc";
import { handleZeroX } from "./zerox";
import { handleChirp, handleChirpHistory, readChirp, type D1Like, type Multicall } from "./chirp";
import { indexIfDue, type RawLog } from "./chirp-index";
import { handleActivity, handleHolders } from "./chirp-routes";
import { ACTIVE_LAUNCHER } from "./launcher-config";
import { indexLauncher, type GetLogsFilter, type LauncherRpc } from "./launcher-index";
import { handleAttachCoinMeta, handleLauncherCoin, handleLauncherCoins, handleLauncherCreator } from "./launcher-routes";
import { handleImageGet, handleImageUpload, handleMetaGet, handleMetaUpload, type R2BucketLike } from "./launcher-images";
import { handleLauncherStake, handleVeMetadata } from "./launcher-ve";
import { runPegWatch, PEG_WATCH_CRON } from "./pegwatch";
import { postTweet } from "./xpost";
import { safeErr } from "./redact";

export type Env = {
  CHIRP_DB: D1Like;
  LAUNCHER_IMAGES?: R2BucketLike;
  RPC_URL?: string;
  ZEROX_API_KEY?: string;
  X_POSTS?: string;
  X_API_KEY?: string;
  X_API_SECRET?: string;
  X_ACCESS_TOKEN?: string;
  X_ACCESS_SECRET?: string;
  ZEROX_LIMITER: { limit(o: { key: string }): Promise<{ success: boolean }> };
  RPC_LIMITER: { limit(o: { key: string }): Promise<{ success: boolean }> };
  IMG_LIMITER?: { limit(o: { key: string }): Promise<{ success: boolean }> };
};

const BASE_CHAIN_ID = 8453;
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const PUBLIC_BASE_RPCS = [
  "https://mainnet.base.org",
  "https://base-rpc.publicnode.com",
];

function client(env: Env) {
  const legs = [env.RPC_URL, ...PUBLIC_BASE_RPCS].filter((u): u is string => !!u);
  const transport = legs.length > 1 ? fallback(legs.map((u) => http(u))) : http(legs[0]);
  return createPublicClient({ transport });
}

function rateLimited(): Response {
  return new Response(JSON.stringify({ error: "rate limited — try again shortly" }), {
    status: 429,
    headers: { "content-type": "application/json" },
  });
}

async function dispatch(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const ip = request.headers.get("cf-connecting-ip") ?? "anon";

  if (url.pathname.startsWith("/api/0x/")) {
    if (!(await env.ZEROX_LIMITER.limit({ key: ip })).success) return rateLimited();
    return handleZeroX(url, env.ZEROX_API_KEY, BASE_CHAIN_ID);
  }

  if (url.pathname === "/api/rpc") {
    if (!(await env.RPC_LIMITER.limit({ key: ip })).success) return rateLimited();
    return handleRpcProxy(request, env.RPC_URL);
  }

  if (
    url.pathname === "/api/chirp" ||
    url.pathname === "/api/chirp/activity" ||
    url.pathname === "/api/chirp/holders" ||
    url.pathname === "/api/chirp/history"
  ) {
    if (!(await env.RPC_LIMITER.limit({ key: ip })).success) return rateLimited();
    if (url.pathname === "/api/chirp/activity") return handleActivity(env.CHIRP_DB, url);
    if (url.pathname === "/api/chirp/holders") return handleHolders(env.CHIRP_DB);
    if (url.pathname === "/api/chirp/history") return handleChirpHistory(env.CHIRP_DB, url, Math.floor(Date.now() / 1000));
    return refreshChirp(env, Date.now());
  }

  if (url.pathname === "/api/launcher/image") {
    if (request.method === "POST" && env.IMG_LIMITER && !(await env.IMG_LIMITER.limit({ key: ip })).success) {
      return rateLimited();
    }
    return handleImageUpload(request, env.LAUNCHER_IMAGES, url.origin);
  }
  if (url.pathname.startsWith("/api/launcher/image/")) {
    return handleImageGet(url.pathname.slice("/api/launcher/image/".length), env.LAUNCHER_IMAGES);
  }

  if (url.pathname === "/api/launcher/meta") {
    if (request.method === "POST" && env.IMG_LIMITER && !(await env.IMG_LIMITER.limit({ key: ip })).success) {
      return rateLimited();
    }
    return handleMetaUpload(request, env.LAUNCHER_IMAGES, url.origin);
  }
  if (url.pathname.startsWith("/api/launcher/meta/")) {
    return handleMetaGet(url.pathname.slice("/api/launcher/meta/".length), env.LAUNCHER_IMAGES);
  }

  if (url.pathname === "/api/launcher/coin-meta") {
    if (request.method === "POST" && env.IMG_LIMITER && !(await env.IMG_LIMITER.limit({ key: ip })).success) {
      return rateLimited();
    }
    return handleAttachCoinMeta(request, env.CHIRP_DB, env.LAUNCHER_IMAGES, ACTIVE_LAUNCHER, launcherRpc(env), url.origin);
  }

  if (url.pathname.startsWith("/api/launcher/ve/")) {
    if (!(await env.RPC_LIMITER.limit({ key: ip })).success) return rateLimited();
    const id = url.pathname.slice("/api/launcher/ve/".length);
    return handleVeMetadata(id, env.CHIRP_DB, ACTIVE_LAUNCHER, launcherRpc(env), url.origin);
  }

  if (
    url.pathname === "/api/launcher/coins" ||
    url.pathname === "/api/launcher/coin" ||
    url.pathname === "/api/launcher/creator" ||
    url.pathname === "/api/launcher/stake"
  ) {
    if (!(await env.RPC_LIMITER.limit({ key: ip })).success) return rateLimited();
    const rpc = launcherRpc(env);
    const nowMs = Date.now();
    if (url.pathname === "/api/launcher/coins") return handleLauncherCoins(env.CHIRP_DB, url, ACTIVE_LAUNCHER, rpc, nowMs, env.LAUNCHER_IMAGES);
    if (url.pathname === "/api/launcher/coin") return handleLauncherCoin(env.CHIRP_DB, url, ACTIVE_LAUNCHER, rpc, nowMs, env.LAUNCHER_IMAGES);
    if (url.pathname === "/api/launcher/stake") return handleLauncherStake(env.CHIRP_DB, url, ACTIVE_LAUNCHER, rpc);
    return handleLauncherCreator(env.CHIRP_DB, url, ACTIVE_LAUNCHER, rpc, nowMs);
  }

  return new Response(JSON.stringify({ error: "not found" }), {
    status: 404,
    headers: { "content-type": "application/json" },
  });
}

function launcherRpc(env: Env): LauncherRpc | null {
  if (!env.RPC_URL) return null;
  const keyed = createPublicClient({ transport: http(env.RPC_URL) });
  return {
    getBlockNumber: async () => Number(await keyed.getBlockNumber({ cacheTime: 0 })),
    getLogs: (filter: GetLogsFilter) =>
      keyed.request({
        method: "eth_getLogs",
        params: [
          {
            ...(filter.address ? { address: filter.address } : {}),
            ...(filter.topics ? { topics: filter.topics } : {}),
            fromBlock: `0x${filter.fromBlock.toString(16)}`,
            toBlock: `0x${filter.toBlock.toString(16)}`,
          },
        ],
      } as never) as Promise<RawLog[]>,
    multicall: (contracts) =>
      keyed.multicall({ contracts: contracts as never, allowFailure: false, multicallAddress: MULTICALL3 }) as Promise<unknown[]>,
    multicallOptional: (contracts) =>
      keyed.multicall({ contracts: contracts as never, allowFailure: true, multicallAddress: MULTICALL3 }) as Promise<
        { status: "success" | "failure"; result?: unknown }[]
      >,
  };
}

function refreshChirp(env: Env, nowMs: number): Promise<Response> {
  const c = client(env);
  const multicall: Multicall = (contracts) =>
    c.multicall({ contracts: contracts as never, allowFailure: false, multicallAddress: MULTICALL3 }) as Promise<unknown[]>;
  const keyed = env.RPC_URL ? createPublicClient({ transport: http(env.RPC_URL) }) : null;
  const index = keyed
    ? (snap: Awaited<ReturnType<typeof readChirp>>, tsMs: number) =>
        indexIfDue(
          env.CHIRP_DB,
          {
            pintoInCurve: snap.curve.pintoInCurve,
            chirpReserve: snap.curve.chirpReserve,
            pile: snap.field.pile,
            plots: String(snap.field.plots.length),
            supply: snap.field.supply,
          },
          tsMs,
          async () => Number(await keyed.getBlockNumber({ cacheTime: 0 })),
          (from, to) =>
            keyed.request({
              method: "eth_getLogs",
              params: [{ address: [snap.book, snap.tokens.chirp], fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}` }],
            } as never) as Promise<RawLog[]>,
        )
    : undefined;
  return handleChirp(env.CHIRP_DB, (nowSec) => readChirp(multicall, nowSec), nowMs, index);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const res = await dispatch(request, env);
    res.headers.set("x-content-type-options", "nosniff");
    return res;
  },

  async scheduled(controller: { cron?: string }, env: Env): Promise<void> {
    if (controller?.cron === PEG_WATCH_CRON) {
      const now = Date.now();
      await runPegWatch(
        env,
        async () => {
          await refreshChirp(env, now);
          try {
            const rpc = launcherRpc(env);
            if (rpc) await indexLauncher(env.CHIRP_DB, rpc, ACTIVE_LAUNCHER, now, false, env.LAUNCHER_IMAGES);
          } catch (e) {
            console.error("peg watch launcher index skipped:", safeErr(e));
          }
        },
        now,
        (text, keys) => postTweet(text, keys),
        undefined,
        ACTIVE_LAUNCHER.factory,
      );
      return;
    }

    const lRpc = launcherRpc(env);
    if (lRpc) {
      try {
        await indexLauncher(env.CHIRP_DB, lRpc, ACTIVE_LAUNCHER, Date.now(), true, env.LAUNCHER_IMAGES);
      } catch (e) {
        console.error("launcher index skipped:", safeErr(e, env.RPC_URL, env.ZEROX_API_KEY));
      }
    }
  },
};
