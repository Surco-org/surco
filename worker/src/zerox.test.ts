import { describe, it, expect, vi } from "vitest";
import { handleZeroX } from "./zerox";

const okBody = { buyAmount: "123", liquidityAvailable: true, transaction: { to: "0xdead", data: "0x", value: "0" } };
function fakeFetch(captured: { url?: string; headers?: Record<string, string> }) {
  return vi.fn(async (input: any, init: any) => {
    captured.url = String(input);
    captured.headers = init?.headers ?? {};
    return new Response(JSON.stringify(okBody), { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
}
const q = (qs: string) => new URL(`https://x/api/0x/quote?${qs}`);
const goodQs = "chainId=8453&sellToken=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE&buyToken=0xb170000aeeFa790fa61D6e837d1035906839a3c8&sellAmount=1000&taker=0x00000000000000000000000000000000000000A1&slippageBps=50";

describe("handleZeroX", () => {
  it("proxies to 0x with the api key + version headers and returns the body", async () => {
    const cap: any = {};
    const res = await handleZeroX(q(goodQs), "SECRET", 8453, fakeFetch(cap));
    expect(res.status).toBe(200);
    expect(cap.url).toContain("https://api.0x.org/swap/allowance-holder/quote");
    expect(cap.url).toContain("sellAmount=1000");
    expect(cap.headers["0x-api-key"]).toBe("SECRET");
    expect(cap.headers["0x-version"]).toBe("v2");
    const body = await res.text();
    expect(body).not.toContain("SECRET"); // key never echoed
    expect(JSON.parse(body).buyAmount).toBe("123");
  });

  it("400s when the api key is unset", async () => {
    const res = await handleZeroX(q(goodQs), undefined, 8453, fakeFetch({}));
    expect(res.status).toBe(400);
  });

  it("400s on an unknown path", async () => {
    const res = await handleZeroX(new URL("https://x/api/0x/evil"), "S", 8453, fakeFetch({}));
    expect(res.status).toBe(400);
  });

  it("400s on a chainId that doesn't match the deployment", async () => {
    const res = await handleZeroX(q(goodQs.replace("chainId=8453", "chainId=1")), "S", 8453, fakeFetch({}));
    expect(res.status).toBe(400);
  });

  it("400s when taker is not an address", async () => {
    const res = await handleZeroX(q(goodQs.replace(/taker=[^&]+/, "taker=notanaddr")), "S", 8453, fakeFetch({}));
    expect(res.status).toBe(400);
  });

  it("only forwards whitelisted params (drops junk)", async () => {
    const cap: any = {};
    await handleZeroX(q(goodQs + "&evil=1"), "S", 8453, fakeFetch(cap));
    expect(cap.url).not.toContain("evil=1");
  });

  it("502s when 0x errors", async () => {
    const failFetch = (async () => new Response("upstream", { status: 500 })) as unknown as typeof fetch;
    const res = await handleZeroX(q(goodQs), "S", 8453, failFetch);
    expect(res.status).toBe(502);
  });
  it("400s a pair with no Pinto side, and never calls 0x", async () => {
    const f = fakeFetch({});
    const weth = "0x4200000000000000000000000000000000000006", usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
    const res = await handleZeroX(new URL(`https://x/api/0x/price?chainId=8453&sellToken=${weth}&buyToken=${usdc}&sellAmount=1`), "SECRET", 8453, f);
    expect(res.status).toBe(400);
    expect(f).not.toHaveBeenCalled();
  });

  it("allows Pinto on either side, any case (/app sells any token for Pinto; /chirp sells Pinto out)", async () => {
    const usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", pinto = "0xB170000AEEFA790FA61D6E837D1035906839A3C8";
    const res = await handleZeroX(new URL(`https://x/api/0x/price?chainId=8453&sellToken=${pinto}&buyToken=${usdc}&sellAmount=1`), "SECRET", 8453, fakeFetch({}));
    expect(res.status).toBe(200);
  });
});
