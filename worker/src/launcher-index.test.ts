import { describe, expect, it } from "vitest";
import { encodeAbiParameters, encodeEventTopics, parseAbi, parseAbiParameters, type Address, type Hex } from "viem";
import { testDb } from "./test-d1";
import { BASE_POOL_MANAGER, BASE_WETH, type LauncherConfig } from "./launcher-config";
import {
  computeCreatorPayouts,
  computePoolId,
  decodeSlot0,
  indexLauncher,
  sqrtPriceToWethPerCoin,
  wethUsdcSqrtPriceToUsd,
  type CoinRow,
  type LauncherRpc,
} from "./launcher-index";
import type { RawLog } from "./chirp-index";

const CFG: LauncherConfig = {
  factory: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  hook: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  safe: "0xcccccccccccccccccccccccccccccccccccccccc",
  deployBlock: 60_330_327,
  isTest: true,
};

const COIN = "0xdddddddddddddddddddddddddddddddddddddddd" as Address;
const VAULT = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as Address;
const CREATOR = "0x9999999999999999999999999999999999999999" as Address;
const NEW_CREATOR = "0x1111111111111111111111111111111111111111" as Address;

const EVT_ABI = parseAbi([
  "event Launched(address indexed coin, address vault, bytes32 indexed id, address indexed launcher, uint8 mode, uint16 feeBps, uint16 creatorBps, uint256 firstBuyWeth, uint256 coinsBought)",
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
  "event Converted(uint256 wethIn, uint256 pintoOut, uint256 tip)",
  "event Seeded(address indexed caller, uint256 amount)",
  "event CreatorPayoutChanged(address indexed previous, address indexed next)",
  "event Transfer(address indexed from, address indexed to, uint256 value)",
]);

function makeLog(address: string, topics: string[], data: Hex, block: number, logIndex: number, tx: string, ts: number): RawLog {
  return {
    address,
    topics,
    data,
    blockNumber: `0x${block.toString(16)}`,
    logIndex: `0x${logIndex.toString(16)}`,
    transactionHash: tx,
    blockTimestamp: `0x${ts.toString(16)}`,
  };
}

describe("launcher-index", () => {
  it("computes poolId, unpacks slot0 signed tick, and converts sqrtPriceX96", () => {
    const { poolId, coinIsToken0 } = computePoolId(COIN, CFG.hook);
    expect(poolId).toMatch(/^0x[0-9a-f]{64}$/);
    expect(coinIsToken0).toBe(false); // 0xd0dc > 0x4200

    // Pack sqrtPrice = 2^96 (ratio = 1) and tick = -200 (0xffff38 in 24-bit two's complement)
    const q96 = 1n << 96n;
    const tickU24 = BigInt(0x1000000 - 200);
    const packed = (`0x${((tickU24 << 160n) | q96).toString(16).padStart(64, "0")}`) as Hex;
    const s0 = decodeSlot0(packed);
    expect(s0.sqrtPriceX96).toBe(q96);
    expect(s0.tick).toBe(-200);
    expect(sqrtPriceToWethPerCoin(q96, true)).toBeCloseTo(1, 8);
    expect(sqrtPriceToWethPerCoin(q96, false)).toBeCloseTo(1, 8);

    // WETH/USDC: $2500/ETH -> sqrt(2500 / 1e12) * 2^96 = 5e-5 * 2^96
    const sqrtWethUsd = BigInt(Math.round(Math.sqrt(2500 / 1e12) * 2 ** 96));
    expect(wethUsdcSqrtPriceToUsd(sqrtWethUsd)).toBeCloseTo(2500, 0);
  });

  it("indexes Launched, Swap, Converted, Seeded, and WETH creator payouts into D1 atomically", async () => {
    const db = testDb();
    const { poolId, coinIsToken0 } = computePoolId(COIN, CFG.hook);
    const sqrtCoin = BigInt(Math.round(Math.sqrt(1e8) * 2 ** 96)); // ~1e-8 WETH per coin when !coinIsToken0
    const sqrtWethUsd = BigInt(Math.round(Math.sqrt(3000 / 1e12) * 2 ** 96));

    const launchedTopics = encodeEventTopics({
      abi: EVT_ABI,
      eventName: "Launched",
      args: { coin: COIN, id: poolId, launcher: CREATOR },
    }) as string[];
    const launchedData = encodeAbiParameters(
      parseAbiParameters("address, uint8, uint16, uint16, uint256, uint256"),
      [VAULT, 1, 100, 1000, 1_000_000_000_000_000n, 98_831_000_000_000_000_000_000n],
    );

    const swapTopics = encodeEventTopics({
      abi: EVT_ABI,
      eventName: "Swap",
      args: { id: poolId, sender: CREATOR },
    }) as string[];
    // !coinIsToken0 -> amount0 is WETH (-0.01 ETH paid by buyer), amount1 is coin (+1e24 received)
    const swapData = encodeAbiParameters(
      parseAbiParameters("int128, int128, uint160, uint128, int24, uint24"),
      [-10_000_000_000_000_000n, 1_000_000_000_000_000_000_000_000n, sqrtCoin, 1_000n, 184200, 0],
    );

    const convTopics = encodeEventTopics({ abi: EVT_ABI, eventName: "Converted" }) as string[];
    const convData = encodeAbiParameters(parseAbiParameters("uint256, uint256, uint256"), [70_000_000_000_000n, 2_580_000n, 350_000_000_000n]);

    const seedTopics = encodeEventTopics({ abi: EVT_ABI, eventName: "Seeded", args: { caller: CREATOR } }) as string[];
    const seedData = encodeAbiParameters(parseAbiParameters("uint256"), [27_970_000n]);

    // Creator payout WETH transfer from split() (10_000_000_000_000n) + convert() tip to same creator (350_000_000_000n, excluded!)
    const wethSplitTopics = encodeEventTopics({
      abi: EVT_ABI,
      eventName: "Transfer",
      args: { from: VAULT, to: CREATOR },
    }) as string[];
    const wethSplitData = encodeAbiParameters(parseAbiParameters("uint256"), [10_000_000_000_000n]);
    const wethTipData = encodeAbiParameters(parseAbiParameters("uint256"), [350_000_000_000n]);

    const tx1 = `0x${"11".repeat(32)}`;
    const tx2 = `0x${"22".repeat(32)}`;
    const tx3 = `0x${"33".repeat(32)}`;
    const nowSec = 1_795_000_000;

    const allLogs = [
      makeLog(CFG.factory, launchedTopics, launchedData, 60_330_330, 1, tx1, nowSec - 300),
      makeLog(BASE_POOL_MANAGER, swapTopics, swapData, 60_330_340, 2, tx2, nowSec - 100),
      makeLog(BASE_WETH, wethSplitTopics, wethSplitData, 60_330_350, 1, tx3, nowSec - 50),
      makeLog(BASE_WETH, wethSplitTopics, wethTipData, 60_330_350, 2, tx3, nowSec - 50),
      makeLog(VAULT, convTopics, convData, 60_330_350, 3, tx3, nowSec - 50),
      makeLog(VAULT, seedTopics, seedData, 60_330_355, 1, tx3, nowSec - 20),
    ];

    const slotWord = (`0x${sqrtCoin.toString(16).padStart(64, "0")}`) as Hex;

    const rpc: LauncherRpc = {
      getBlockNumber: async () => 60_330_400,
      getLogs: async (filter) => {
        const addrs = Array.isArray(filter.address)
          ? filter.address.map((a) => a.toLowerCase())
          : filter.address
            ? [filter.address.toLowerCase()]
            : [];
        return allLogs.filter(
          (l) =>
            Number(l.blockNumber) >= filter.fromBlock &&
            Number(l.blockNumber) <= filter.toBlock &&
            (addrs.length === 0 || addrs.includes(l.address.toLowerCase())),
        );
      },
      multicall: async (calls) => {
        // Ref prices call (2 items) vs new coin metadata call (5 items)
        if (calls.length === 2 && calls[0].functionName === "slot0") {
          return [[sqrtWethUsd, 0, 0, 0, 0, 0, true], 2_000_000n]; // $0.02 Pinto
        }
        return [
          "TEST Burn",
          "DEMO",
          "https://surcofi.com/api/launcher/image/abc.png",
          CREATOR,
          [VAULT, 100, BigInt(nowSec - 300), coinIsToken0, 0n, 0n],
        ];
      },
      multicallOptional: async (calls) => {
        if (calls.length === 1 && calls[0].functionName === "metadataURI") {
          return [{ status: "failure" }]; // TEST factory has no metadataURI
        }
        return [
          { status: "success", result: slotWord },
          { status: "success", result: 30_550_000n }, // siloPinto = 30.55
          { status: "success", result: 5_000_000_000_000n }, // pendingPintoWeth
          { status: "success", result: 25_000_000_000_000n }, // vault WETH balance -> 20e12 unsplit
          { status: "success", result: 1_000_000_000n * 10n ** 18n }, // totalSupply
          { status: "success", result: 0n }, // yieldPinto
        ];
      },
    };

    const res = await indexLauncher(db, rpc, CFG, nowSec * 1000, false);
    expect(res.newCoins).toBe(1);
    expect(res.swaps).toBe(1);
    expect(res.vaultEvents).toBe(2);

    const coin = await db
      .prepare("SELECT * FROM launcher_coins WHERE factory = ? AND coin = ?")
      .bind(CFG.factory.toLowerCase(), COIN.toLowerCase())
      .first<CoinRow>();
    expect(coin).not.toBeNull();
    expect(coin!.name).toBe("TEST Burn");
    expect(coin!.symbol).toBe("DEMO");
    expect(coin!.silo_pinto).toBe("30550000");
    expect(coin!.unsplit_weth).toBe("20000000000000");
    expect(coin!.trades_24h).toBe(1);
    expect(coin!.vol_24h_weth).toBeCloseTo(0.01, 6);
    // Creator paid excludes the 350e9 convert() tip!
    expect(coin!.creator_paid_weth).toBe("10000000000000");

    // Re-running with no new blocks is a clean no-op (cursor already at 60_330_395)
    const res2 = await indexLauncher(db, rpc, CFG, (nowSec + 60) * 1000, false);
    expect(res2.newCoins).toBe(0);
    expect(res2.swaps).toBe(0);
  });

  it("tracks CreatorPayoutChanged mid-range when attributing WETH transfers", () => {
    const t1 = encodeEventTopics({ abi: EVT_ABI, eventName: "Transfer", args: { from: VAULT, to: CREATOR } }) as string[];
    const t2 = encodeEventTopics({ abi: EVT_ABI, eventName: "Transfer", args: { from: VAULT, to: NEW_CREATOR } }) as string[];
    const tx = `0x${"aa".repeat(32)}`;
    const wethLogs = [
      makeLog(BASE_WETH, t1, encodeAbiParameters(parseAbiParameters("uint256"), [100n]), 10, 1, tx, 1000),
      makeLog(BASE_WETH, t2, encodeAbiParameters(parseAbiParameters("uint256"), [250n]), 10, 3, tx, 1000),
    ];
    const vaultEvents = [
      {
        vault: VAULT.toLowerCase(),
        block: 10,
        logIdx: 2,
        tx,
        t: 1000,
        kind: "payout_changed" as const,
        actor: NEW_CREATOR.toLowerCase(),
        amountA: "0",
        amountB: "0",
        tip: "0",
      },
    ];
    const initial = new Map([[VAULT.toLowerCase(), CREATOR.toLowerCase()]]);
    const { deltaByVault, latestPayoutByVault } = computeCreatorPayouts(wethLogs, vaultEvents, initial);
    expect(deltaByVault.get(VAULT.toLowerCase())).toBe(350n);
    expect(latestPayoutByVault.get(VAULT.toLowerCase())).toBe(NEW_CREATOR.toLowerCase());
  });
});
