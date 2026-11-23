// Worker endpoints for the Collective Silo + veChirp NFT Gauge:
//   - GET /api/launcher/ve/<lockId>   -> ERC-721 metadata JSON + inline SVG card (CORS *)
//   - GET /api/launcher/stake?a=<addr> -> Collective Silo stats, coin ve-weights, and optional wallet veNFTs
import { isAddress, parseAbi, type Address } from "viem";
import type { D1Like } from "./chirp";
import { BASE_PINTO, BASE_WETH, type LauncherConfig } from "./launcher-config";
import { ensureLauncherState, type LauncherRpc } from "./launcher-index";

const MAX_DAYS = 365n;

const VE_ABI = parseAbi([
  "function ownerOf(uint256 id) view returns (address)",
  "function claimantOf(uint256 id) view returns (address)",
  "function latestSnap(uint256 id) view returns ((uint32 fromDay, uint32 endDay, bool permanent, address coin, uint128 amount))",
  "function lockStateAt(uint256 id, uint32 day) view returns (address coin, uint256 weight)",
  "function currentDay() view returns (uint32)",
  "function totalLocked() view returns (uint256)",
  "function nextId() view returns (uint256)",
  "function previewTotalWeightAt(uint32 day) view returns (uint256)",
  "function previewCoinWeightAt(address coin, uint32 day) view returns (uint256)",
]);

const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as `0x${string}`;
const DIRECT_SCAN_CAP = 200;
const LOG_SPAN = 10_000;
const LOG_MIN_SPAN = 1_000;
const MAX_LOG_CALLS = 16;

const COLLECTIVE_ABI = parseAbi([
  "function siloPinto() view returns (uint256)",
  "function yieldPinto() view returns (uint256)",
  "function lastClaimedDay(uint256 lockId) view returns (uint32)",
  "function dayPinto(uint32 day) view returns (uint256)",
  "function dayTotalWeight(uint32 day) view returns (uint256)",
]);

const ERC20_BAL_ABI = parseAbi(["function balanceOf(address) view returns (uint256)"]);

type SnapTuple = {
  fromDay: number;
  endDay: number;
  permanent: boolean;
  coin: Address;
  amount: bigint;
};

const json = (body: unknown, status = 200, maxAge: number | null = 10, cors = false) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": maxAge === null ? "no-store" : `public, max-age=${maxAge}`,
      ...(cors ? { "access-control-allow-origin": "*" } : {}),
    },
  });

function toUtf8Base64(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function escXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function fmtChirp(wei: bigint): string {
  const n = Number(wei) / 1e18;
  if (!Number.isFinite(n) || n <= 0) return "0";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return n.toLocaleString("en-US", { maximumFractionDigits: 1 });
  return n.toFixed(2);
}

/** Exact mirror of VeChirp.lockStateAt weight math. */
export function computeLockWeight(snap: SnapTuple, day: number): bigint {
  if (snap.amount <= 0n) return 0n;
  if (day < snap.fromDay) {
    // Pending activation tomorrow: show effective weight at fromDay for preview clarity.
    return snap.permanent
      ? snap.amount
      : snap.endDay > snap.fromDay
        ? (snap.amount * BigInt(snap.endDay - snap.fromDay)) / MAX_DAYS
        : 0n;
  }
  if (snap.permanent) return snap.amount;
  if (day >= snap.endDay) return 0n;
  return (snap.amount * BigInt(snap.endDay - day)) / MAX_DAYS;
}

/** Builds a clean, self-contained SVG data URI for a veChirp NFT card. */
export function buildVeCardSvg(params: {
  id: string;
  amountWei: bigint;
  weightWei: bigint;
  permanent: boolean;
  remainingDays: number;
  pending: boolean;
  coinLabel: string;
}): string {
  const amt = escXml(`${fmtChirp(params.amountWei)} CHIRP`);
  const w = escXml(`${fmtChirp(params.weightWei)} veCHIRP`);
  const status = params.permanent
    ? "Permanent Max-Lock (100%)"
    : params.remainingDays > 0
      ? `${params.remainingDays}d remaining`
      : "Unlocked (ready to withdraw)";
  const badge = escXml(params.pending ? `Activates tomorrow · ${status}` : status);
  const coin = escXml(params.coinLabel);
  const idStr = escXml(params.id);

  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 360" width="600" height="360">` +
    `<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0%" stop-color="#1e281d"/><stop offset="100%" stop-color="#121912"/></linearGradient></defs>` +
    `<rect width="600" height="360" rx="24" fill="url(#bg)"/>` +
    `<rect x="16" y="16" width="568" height="328" rx="18" fill="none" stroke="#c89b54" stroke-opacity="0.35" stroke-width="1.5"/>` +
    `<circle cx="520" cy="72" r="24" fill="#e6b655" fill-opacity="0.22"/>` +
    `<circle cx="520" cy="72" r="14" fill="#e6b655"/>` +
    `<text x="40" y="64" fill="#c89b54" font-family="ui-monospace,SFMono-Regular,monospace" font-size="14" letter-spacing="2">SURCO · COLLECTIVE SILO</text>` +
    `<text x="40" y="106" fill="#f7f3e8" font-family="Georgia,serif" font-size="36" font-weight="700">veChirp #${idStr}</text>` +
    `<text x="40" y="142" fill="#b7c4b0" font-family="system-ui,sans-serif" font-size="16">${badge}</text>` +
    `<text x="40" y="206" fill="#90a188" font-family="system-ui,sans-serif" font-size="13">LOCKED CHIRP</text>` +
    `<text x="40" y="232" fill="#f7f3e8" font-family="ui-monospace,SFMono-Regular,monospace" font-size="22" font-weight="600">${amt}</text>` +
    `<text x="320" y="206" fill="#90a188" font-family="system-ui,sans-serif" font-size="13">GAUGE WEIGHT</text>` +
    `<text x="320" y="232" fill="#e6b655" font-family="ui-monospace,SFMono-Regular,monospace" font-size="22" font-weight="600">${w}</text>` +
    `<line x1="40" y1="266" x2="560" y2="266" stroke="#c89b54" stroke-opacity="0.22"/>` +
    `<text x="40" y="302" fill="#90a188" font-family="system-ui,sans-serif" font-size="13">BACKING COIN</text>` +
    `<text x="40" y="324" fill="#f7f3e8" font-family="system-ui,sans-serif" font-size="18" font-weight="600">${coin}</text>` +
    `</svg>`;
  return `data:image/svg+xml;base64,${toUtf8Base64(svg)}`;
}

/** GET /api/launcher/ve/<lockId> — ERC-721 metadata JSON for a veChirp NFT. */
export async function handleVeMetadata(
  idRaw: string,
  db: D1Like,
  cfg: LauncherConfig,
  rpc: LauncherRpc | null,
  origin: string,
): Promise<Response> {
  const cleanId = idRaw.replace(/\.json$/i, "").trim();
  if (!/^[1-9][0-9]{0,18}$/.test(cleanId)) {
    return json({ error: "invalid lock id" }, 400, 0, true);
  }
  if (!cfg.veChirp || !rpc) {
    return json({ error: "veChirp not active on this deployment" }, 404, 5, true);
  }

  const lockId = BigInt(cleanId);
  const res = await rpc.multicallOptional([
    { address: cfg.veChirp, abi: VE_ABI, functionName: "ownerOf", args: [lockId] },
    { address: cfg.veChirp, abi: VE_ABI, functionName: "latestSnap", args: [lockId] },
    { address: cfg.veChirp, abi: VE_ABI, functionName: "currentDay" },
  ]);

  const owner = res[0]?.status === "success" ? (res[0].result as Address) : null;
  if (!owner || owner === "0x0000000000000000000000000000000000000000") {
    return json({ error: "veChirp NFT not found" }, 404, 5, true);
  }
  if (res[1]?.status !== "success" || res[2]?.status !== "success") {
    return json({ error: "failed to read lock state" }, 502, 0, true);
  }

  const snap = res[1].result as SnapTuple;
  const today = Number(res[2].result as number | bigint);
  const weight = computeLockWeight(snap, today);
  const pending = today < snap.fromDay;
  const remainingDays = snap.permanent
    ? 365
    : Math.max(0, snap.endDay - (pending ? snap.fromDay : today));

  const coinAddr = snap.coin.toLowerCase();
  const coinRow = await db
    .prepare("SELECT name, symbol FROM launcher_coins WHERE factory = ? AND coin = ?")
    .bind(cfg.factory.toLowerCase(), coinAddr)
    .first<{ name: string; symbol: string }>();
  const coinLabel = coinRow ? `$${coinRow.symbol} (${coinRow.name})` : `${snap.coin.slice(0, 6)}…${snap.coin.slice(-4)}`;

  const image = buildVeCardSvg({
    id: cleanId,
    amountWei: snap.amount,
    weightWei: weight,
    permanent: snap.permanent,
    remainingDays,
    pending,
    coinLabel,
  });

  const base = origin.replace(/\/$/, "");
  return json(
    {
      name: `veChirp #${cleanId}`,
      description: `Locked Chirp backing ${coinLabel} in the Surco Collective Pinto Silo on Base.`,
      external_url: `${base}/stake`,
      image,
      attributes: [
        { trait_type: "Locked Chirp", value: Number((Number(snap.amount) / 1e18).toFixed(4)) },
        { trait_type: "Gauge Weight", value: Number((Number(weight) / 1e18).toFixed(4)) },
        { trait_type: "Lock Mode", value: snap.permanent ? "Permanent Max-Lock" : "Fixed Term" },
        { trait_type: "Remaining Days", value: remainingDays },
        { trait_type: "Backing Coin", value: coinRow ? coinRow.symbol : coinAddr },
        { trait_type: "Backing Coin Address", value: coinAddr },
      ],
    },
    200,
    15,
    true,
  );
}

/** GET /api/launcher/stake?a=<optionalWallet> — Collective Silo stats, coin weights, and user locks. */
export async function handleLauncherStake(
  db: D1Like,
  url: URL,
  cfg: LauncherConfig,
  rpc: LauncherRpc | null,
): Promise<Response> {
  const walletRaw = (url.searchParams.get("a") ?? "").trim();
  const wallet = walletRaw && isAddress(walletRaw) ? walletRaw.toLowerCase() : null;
  if (walletRaw && !wallet) return json({ error: "invalid wallet address" }, 400, 0);

  const f = cfg.factory.toLowerCase();
  const state = await ensureLauncherState(db, cfg);

  if (!cfg.veChirp || !cfg.collectiveSilo || !rpc) {
    return json({
      active: false,
      factory: f,
      isTest: cfg.isTest,
      veChirp: cfg.veChirp?.toLowerCase() ?? null,
      collectiveSilo: cfg.collectiveSilo?.toLowerCase() ?? null,
      wethUsd: state.weth_usd,
      pintoUsd: state.pinto_usd,
      silo: null,
      coinWeights: {},
      locks: [],
    });
  }

  const headRes = await rpc.multicallOptional([
    { address: cfg.collectiveSilo, abi: COLLECTIVE_ABI, functionName: "siloPinto" },
    { address: cfg.collectiveSilo, abi: COLLECTIVE_ABI, functionName: "yieldPinto" },
    { address: BASE_WETH, abi: ERC20_BAL_ABI, functionName: "balanceOf", args: [cfg.collectiveSilo] },
    { address: BASE_PINTO, abi: ERC20_BAL_ABI, functionName: "balanceOf", args: [cfg.collectiveSilo] },
    { address: cfg.veChirp, abi: VE_ABI, functionName: "totalLocked" },
    { address: cfg.veChirp, abi: VE_ABI, functionName: "currentDay" },
    { address: cfg.veChirp, abi: VE_ABI, functionName: "nextId" },
  ]);

  if (headRes[0]?.status !== "success" || headRes[5]?.status !== "success") {
    return json({ error: "failed to read Collective Silo state" }, 502, null);
  }
  const siloPinto = headRes[0].result as bigint;
  const yieldPinto = headRes[1]?.status === "success" ? (headRes[1].result as bigint) : 0n;
  const pendingWeth = headRes[2]?.status === "success" ? (headRes[2].result as bigint) : 0n;
  const unbookedPinto = headRes[3]?.status === "success" ? (headRes[3].result as bigint) : 0n;
  const totalLocked = headRes[4]?.status === "success" ? (headRes[4].result as bigint) : 0n;
  const today = Number(headRes[5].result as number | bigint);
  const nextId = headRes[6]?.status === "success" ? Number(headRes[6].result as bigint) : 1;

  const coinRows = (
    await db
      .prepare("SELECT coin, name, symbol, image_uri FROM launcher_coins WHERE factory = ? AND hidden = 0 ORDER BY silo_pinto_num DESC, launched_at DESC LIMIT 200")
      .bind(f)
      .all<{ coin: string; name: string; symbol: string; image_uri: string }>()
  ).results;

  const weightCalls = [
    { address: cfg.veChirp, abi: VE_ABI, functionName: "previewTotalWeightAt", args: [today] },
    ...coinRows.map((c) => ({
      address: cfg.veChirp as Address,
      abi: VE_ABI,
      functionName: "previewCoinWeightAt",
      args: [c.coin as Address, today],
    })),
  ];
  const weightRes = today > 0 ? await rpc.multicallOptional(weightCalls) : [];
  const totalWeightToday = weightRes[0]?.status === "success" ? (weightRes[0].result as bigint) : 0n;

  const coinWeights: Record<string, string> = {};
  for (let i = 0; i < coinRows.length; i++) {
    const r = weightRes[i + 1];
    coinWeights[coinRows[i].coin] = r?.status === "success" ? String(r.result as bigint) : "0";
  }

  // Discover candidate lock IDs for `wallet`:
  // - Small sets (<= 200 minted): single multicall over 1..nextId-1.
  // - Large sets (> 200 minted): query ERC-721 Transfer(*, wallet, id) logs so lock #251+ never disappear.
  const locks: {
    id: string;
    owner: string;
    active: boolean;
    coin: string;
    amount: string;
    weight: string;
    fromDay: number;
    endDay: number;
    permanent: boolean;
    remainingDays: number;
    pending: boolean;
    canWithdraw: boolean;
    lastClaimedDay: number;
  }[] = [];

  if (wallet && nextId > 1) {
    let candidateIds: number[] = [];
    if (nextId - 1 <= DIRECT_SCAN_CAP) {
      for (let id = 1; id < nextId; id++) candidateIds.push(id);
    } else {
      // Try D1 indexed table first if present; otherwise bounded 10k-block halving scan (Alchemy-safe).
      const seen = new Set<number>();
      let usedDb = false;
      try {
        const dbRows = (
          await db
            .prepare("SELECT lock_id FROM launcher_ve_locks WHERE ve_chirp = ? AND claimant = ? ORDER BY lock_id ASC LIMIT 250")
            .bind(cfg.veChirp.toLowerCase(), wallet)
            .all<{ lock_id: number }>()
        ).results;
        if (dbRows.length > 0) {
          usedDb = true;
          for (const r of dbRows) {
            if (!seen.has(r.lock_id)) {
              seen.add(r.lock_id);
              candidateIds.push(r.lock_id);
            }
          }
        }
      } catch {
        // Optional D1 table not migrated yet; fall back to bounded getLogs scan.
      }
      if (!usedDb) {
        const padded = (`0x${"0".repeat(24)}${wallet.slice(2)}`) as `0x${string}`;
        const head = await rpc.getBlockNumber();
        let span = LOG_SPAN;
        let from = cfg.deployBlock;
        let calls = 0;
        while (from <= head && calls < MAX_LOG_CALLS) {
          const to = Math.min(head, from + span - 1);
          try {
            calls++;
            const logs = await rpc.getLogs({
              address: cfg.veChirp,
              topics: [TRANSFER_TOPIC, null, padded],
              fromBlock: from,
              toBlock: to,
            });
            for (const l of logs) {
              const idHex = l.topics[3];
              if (!idHex) continue;
              const idNum = Number(BigInt(idHex));
              if (idNum > 0 && !seen.has(idNum)) {
                seen.add(idNum);
                candidateIds.push(idNum);
              }
            }
            from = to + 1;
          } catch {
            if (span > LOG_MIN_SPAN) {
              span = Math.max(LOG_MIN_SPAN, Math.floor(span / 2));
              continue;
            }
            break;
          }
        }
        candidateIds.sort((a, b) => a - b);
      }
    }

    const matchedIds: number[] = [];
    if (candidateIds.length > 0) {
      const idCalls = candidateIds.map((id) => ({
        address: cfg.veChirp as Address,
        abi: VE_ABI,
        functionName: "claimantOf",
        args: [BigInt(id)],
      }));
      const claimants = await rpc.multicallOptional(idCalls);
      for (let i = 0; i < claimants.length; i++) {
        if (claimants[i]?.status === "success" && String(claimants[i].result).toLowerCase() === wallet) {
          matchedIds.push(candidateIds[i]);
        }
      }
    }

    if (matchedIds.length > 0) {
      const detailCalls = matchedIds.flatMap((id) => [
        { address: cfg.veChirp as Address, abi: VE_ABI, functionName: "ownerOf", args: [BigInt(id)] },
        { address: cfg.veChirp as Address, abi: VE_ABI, functionName: "latestSnap", args: [BigInt(id)] },
        { address: cfg.veChirp as Address, abi: VE_ABI, functionName: "lockStateAt", args: [BigInt(id), today] },
        { address: cfg.collectiveSilo as Address, abi: COLLECTIVE_ABI, functionName: "lastClaimedDay", args: [BigInt(id)] },
      ]);
      const details = await rpc.multicallOptional(detailCalls);
      for (let i = 0; i < matchedIds.length; i++) {
        const id = matchedIds[i];
        const ownerRes = details[i * 4];
        const snapRes = details[i * 4 + 1];
        const todayRes = details[i * 4 + 2];
        const claimRes = details[i * 4 + 3];
        if (snapRes?.status !== "success") continue;
        const active = ownerRes?.status === "success" && String(ownerRes.result).toLowerCase() === wallet;
        const snap = snapRes.result as SnapTuple;
        const todayState =
          todayRes?.status === "success" ? (todayRes.result as readonly [Address, bigint]) : null;
        const todayWeight = active && todayState ? todayState[1] : 0n;
        const todayCoin =
          todayState && todayState[0] !== "0x0000000000000000000000000000000000000000"
            ? todayState[0].toLowerCase()
            : snap.coin.toLowerCase();
        const hasPendingChange = today < snap.fromDay;
        const isNewPending = hasPendingChange && todayWeight === 0n;
        const weight = active ? (isNewPending ? computeLockWeight(snap, today) : todayWeight) : 0n;
        const remainingDays = snap.permanent ? 365 : Math.max(0, snap.endDay - (hasPendingChange ? snap.fromDay : today));
        locks.push({
          id: String(id),
          owner: wallet,
          active,
          coin: isNewPending ? snap.coin.toLowerCase() : todayCoin,
          amount: String(snap.amount),
          weight: String(weight),
          fromDay: snap.fromDay,
          endDay: snap.endDay,
          permanent: snap.permanent,
          remainingDays,
          pending: isNewPending,
          canWithdraw: active && !snap.permanent && today >= snap.endDay,
          lastClaimedDay: claimRes?.status === "success" ? Number(claimRes.result as number | bigint) : 0,
        });
      }
    }
  }

  return json(
    {
      active: true,
      factory: f,
      isTest: cfg.isTest,
      veChirp: cfg.veChirp.toLowerCase(),
      collectiveSilo: cfg.collectiveSilo.toLowerCase(),
      wethUsd: state.weth_usd,
      pintoUsd: state.pinto_usd,
      silo: {
        siloPinto: String(siloPinto),
        siloPintoNum: Number(siloPinto) / 1e6,
        siloPintoUsd: (Number(siloPinto) / 1e6) * state.pinto_usd,
        principalPinto: String(siloPinto > yieldPinto ? siloPinto - yieldPinto : 0n),
        yieldPinto: String(yieldPinto),
        pendingWeth: String(pendingWeth),
        unbookedPinto: String(unbookedPinto),
        totalLockedChirp: String(totalLocked),
        totalWeightToday: String(totalWeightToday),
        currentDay: today,
        totalLocks: Math.max(0, nextId - 1),
      },
      coinWeights,
      locks,
    },
    200,
    wallet ? null : 10,
  );
}
