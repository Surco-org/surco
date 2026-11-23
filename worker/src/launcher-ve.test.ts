import { describe, expect, it } from "vitest";
import type { Address } from "viem";
import { buildVeCardSvg, computeLockWeight, handleLauncherStake, handleVeMetadata } from "./launcher-ve";
import type { LauncherConfig } from "./launcher-config";
import type { LauncherRpc } from "./launcher-index";
import type { D1Like } from "./chirp";

const BASE_CFG: LauncherConfig = {
  factory: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  hook: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  safe: "0xcccccccccccccccccccccccccccccccccccccccc",
  deployBlock: 60_330_327,
  isTest: true,
};

const ACTIVE_CFG: LauncherConfig = {
  ...BASE_CFG,
  isTest: false,
  veChirp: "0x1111111111111111111111111111111111111111",
  collectiveSilo: "0x2222222222222222222222222222222222222222",
};

function fakeDb(coinRow: { name: string; symbol: string } | null = null): D1Like {
  const mkStmt = () => ({
    bind: () => mkStmt(),
    first: async <T,>() =>
      (coinRow
        ? coinRow
        : { factory: BASE_CFG.factory.toLowerCase(), cursor_block: 1, last_sync_ms: 0, weth_usd: 2500, pinto_usd: 1 }) as unknown as T,
    all: async <T,>() => ({ results: (coinRow ? [{ coin: "0xaaaa", ...coinRow, image_uri: "" }] : []) as unknown as T[] }),
    run: async () => ({ meta: { changes: 0 } }),
  });
  return {
    prepare: () => mkStmt(),
    batch: async () => [],
  };
}

describe("launcher-ve", () => {
  it("computes linear decay and permanent max-lock weights identically to VeChirp.sol", () => {
    const coin = "0x3333333333333333333333333333333333333333" as Address;
    expect(computeLockWeight({ fromDay: 100, endDay: 0, permanent: true, coin, amount: 365n * 10n ** 18n }, 150)).toBe(
      365n * 10n ** 18n,
    );
    expect(computeLockWeight({ fromDay: 100, endDay: 465, permanent: false, coin, amount: 365n * 10n ** 18n }, 100)).toBe(
      365n * 10n ** 18n,
    );
    expect(computeLockWeight({ fromDay: 100, endDay: 465, permanent: false, coin, amount: 365n * 10n ** 18n }, 200)).toBe(
      265n * 10n ** 18n,
    );
    expect(computeLockWeight({ fromDay: 100, endDay: 465, permanent: false, coin, amount: 365n * 10n ** 18n }, 465)).toBe(0n);
  });

  it("encodes UTF-8 SVG cards cleanly (including emoji, CJK, ellipsis, and XML escaping)", () => {
    const uri = buildVeCardSvg({
      id: "7",
      amountWei: 100n * 10n ** 18n,
      weightWei: 100n * 10n ** 18n,
      permanent: true,
      remainingDays: 365,
      pending: false,
      coinLabel: `$FROG 🐸 日本語 0x1234…abcd <script>&"`,
    });
    expect(uri.startsWith("data:image/svg+xml;base64,")).toBe(true);
    const bin = atob(uri.slice("data:image/svg+xml;base64,".length));
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    const decoded = new TextDecoder().decode(bytes);
    expect(decoded).not.toContain("<script>");
    expect(decoded).toContain("&lt;script&gt;&amp;&quot;");
    expect(decoded).toContain("🐸");
    expect(decoded).toContain("日本語");
    expect(decoded).toContain("SURCO · COLLECTIVE SILO");
  });

  it("returns active:false on /api/launcher/stake while veChirp is not yet deployed", async () => {
    const res = await handleLauncherStake(fakeDb(), new URL("https://surcofi.com/api/launcher/stake"), BASE_CFG, null);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { active: boolean; silo: unknown; locks: unknown[] };
    expect(body.active).toBe(false);
    expect(body.silo).toBeNull();
    expect(body.locks).toEqual([]);
  });

  it("serves ERC-721 metadata JSON with CORS on /api/launcher/ve/:id", async () => {
    const coin = "0x3333333333333333333333333333333333333333" as Address;
    const rpc: LauncherRpc = {
      getBlockNumber: async () => 1,
      getLogs: async () => [],
      multicall: async () => [],
      multicallOptional: async () => [
        { status: "success", result: "0x9999999999999999999999999999999999999999" },
        { status: "success", result: { fromDay: 20100, endDay: 0, permanent: true, coin, amount: 500n * 10n ** 18n } },
        { status: "success", result: 20105 },
      ],
    };
    const res = await handleVeMetadata("1", fakeDb({ name: "Chuck", symbol: "CHUCK" }), ACTIVE_CFG, rpc, "https://surcofi.com");
    expect(res.status).toBe(200);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
    const body = (await res.json()) as { name: string; image: string; attributes: { trait_type: string; value: unknown }[] };
    expect(body.name).toBe("veChirp #1");
    expect(body.image.startsWith("data:image/svg+xml;base64,")).toBe(true);
    expect(body.attributes.find((a) => a.trait_type === "Backing Coin")?.value).toBe("CHUCK");
  });

  it("rejects non-numeric /api/launcher/ve/:id with 400", async () => {
    const res = await handleVeMetadata("abc", fakeDb(), ACTIVE_CFG, null, "https://surcofi.com");
    expect(res.status).toBe(400);
  });

  it("discovers lock #300 via Transfer logs when nextId > 200", async () => {
    const wallet = "0x9999999999999999999999999999999999999999" as Address;
    const coin = "0x3333333333333333333333333333333333333333" as Address;
    let callIdx = 0;
    const rpc: LauncherRpc = {
      getBlockNumber: async () => ACTIVE_CFG.deployBlock + 100,
      getLogs: async () => [
        {
          address: ACTIVE_CFG.veChirp!,
          topics: [
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
            "0x" + "00".repeat(32),
            "0x" + "00".repeat(12) + wallet.slice(2),
            "0x" + (300).toString(16).padStart(64, "0"),
          ],
          data: "0x",
          blockNumber: "0x1",
          blockTimestamp: "0x1",
          transactionHash: "0x" + "11".repeat(32),
          logIndex: "0x0",
        },
      ],
      multicall: async () => [],
      multicallOptional: async () => {
        callIdx++;
        if (callIdx === 1) {
          return [
            { status: "success", result: 100_000_000n },
            { status: "success", result: 0n },
            { status: "success", result: 0n },
            { status: "success", result: 0n },
            { status: "success", result: 500n * 10n ** 18n },
            { status: "success", result: 20105 },
            { status: "success", result: 350n }, // > 200 -> uses log discovery
          ];
        }
        if (callIdx === 2) {
          return [{ status: "success", result: 500n * 10n ** 18n }];
        }
        if (callIdx === 3) {
          return [{ status: "success", result: wallet }];
        }
        return [
          { status: "success", result: wallet },
          { status: "success", result: { fromDay: 20106, endDay: 0, permanent: true, coin, amount: 500n * 10n ** 18n } },
          { status: "success", result: [coin, 500n * 10n ** 18n] }, // active today despite queued same-day edit!
          { status: "success", result: 20104 },
        ];
      },
    };
    const res = await handleLauncherStake(fakeDb(), new URL(`https://surcofi.com/api/launcher/stake?a=${wallet}`), ACTIVE_CFG, rpc);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const body = (await res.json()) as { active: boolean; locks: { id: string; pending: boolean }[] };
    expect(body.active).toBe(true);
    expect(body.locks.map((l) => l.id)).toEqual(["300"]);
    expect(body.locks[0].pending).toBe(false);
  });
});
