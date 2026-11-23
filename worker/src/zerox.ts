// 0x Swap API v2 proxy (allowance-holder). Holds the API key server-side; the browser only ever hits
// this Worker route. Whitelists passthrough params, injects auth headers, forwards to api.0x.org.
const ALLOWED = ["chainId", "sellToken", "buyToken", "sellAmount", "taker", "slippageBps"] as const;
const ADDR = /^0x[0-9a-fA-F]{40}$/;
// Every swap either site makes is into or out of Pinto (/app: any token -> Pinto; /chirp: coin <-> Pinto).
// Requiring Pinto on one side stops the keyed proxy being a free 0x gateway for arbitrary pairs.
const PINTO = "0xb170000aeefa790fa61d6e837d1035906839a3c8";

export async function handleZeroX(
  url: URL,
  apiKey: string | undefined,
  chainId: number,
  doFetch: typeof fetch = fetch,
): Promise<Response> {
  const seg = url.pathname.replace(/^\/api\/0x\//, ""); // "quote" | "price"
  if (seg !== "quote" && seg !== "price") return json({ error: "not found" }, 400);
  if (!apiKey) return json({ error: "swap unavailable (no key configured)" }, 400);

  const taker = url.searchParams.get("taker");
  if (seg === "quote" && (!taker || !ADDR.test(taker))) return json({ error: "bad taker" }, 400);
  const cid = url.searchParams.get("chainId");
  if (cid !== String(chainId)) return json({ error: "wrong chainId" }, 400);

  const sell = url.searchParams.get("sellToken") ?? "", buy = url.searchParams.get("buyToken") ?? "";
  if (!ADDR.test(sell) || !ADDR.test(buy)) return json({ error: "bad token" }, 400);
  if (sell.toLowerCase() !== PINTO && buy.toLowerCase() !== PINTO) return json({ error: "one side must be Pinto" }, 400);

  const out = new URLSearchParams();
  for (const k of ALLOWED) { const v = url.searchParams.get(k); if (v) out.set(k, v); }

  let upstream: Response;
  try {
    upstream = await doFetch(`https://api.0x.org/swap/allowance-holder/${seg}?${out.toString()}`, {
      headers: { "0x-api-key": apiKey, "0x-version": "v2" },
    });
  } catch {
    return json({ error: "swap quote failed (network)" }, 502);
  }
  if (!upstream.ok) return json({ error: `swap quote failed (${upstream.status})` }, 502);
  const body = await upstream.text();
  return new Response(body, { status: 200, headers: { "content-type": "application/json" } });
}

function json(o: unknown, status: number): Response {
  return new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
}
