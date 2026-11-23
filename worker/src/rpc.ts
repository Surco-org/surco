// Read-only JSON-RPC proxy. The browser can't use our keyed Alchemy endpoint (it would ship in the
// bundle and leak), so the client points its READS here and the Worker forwards them to the keyed RPC
// server-side — killing the public-RPC flakiness that shows as "Read failed" on the dApp. Writes never
// come through here (the wallet broadcasts its own signed txns), and we hard-block any non-read method
// so this can't be abused to broadcast or burn quota.

// Only read methods needed by the client (eth_call via Multicall3, gas price, balances, receipt polling).
// Gas estimation and sends go through the user's wallet. Costly methods (eth_getLogs, eth_estimateGas,
// eth_feeHistory) are excluded to protect upstream RPC quota.
const READ_METHODS = new Set<string>([
  "eth_call", "eth_chainId", "eth_blockNumber", "eth_getBalance", "eth_gasPrice",
  "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getTransactionCount",
  "eth_getBlockByNumber", "eth_getCode", "net_version",
]);

const MAX_BODY_BYTES = 128 * 1024; // generous for a batched read payload; blocks abuse
// A single POST is one hit against RPC_LIMITER (600/min/IP) but a JSON-RPC batch fans out to one
// upstream call PER element — so an uncapped batch multiplies the keyed-Alchemy quota an attacker can
// burn per rate-limited request (denial-of-wallet / free public gateway). Cap the fan-out. A real dApp
// /app never sends a JSON-RPC batch (viem plain http(); reads coalesce into one Multicall3 eth_call), so
// one POST = one upstream call.
export const MAX_BATCH = 1;

const json = (o: unknown, status: number): Response =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

type FetchLike = typeof fetch;

export async function handleRpcProxy(
  request: Request,
  rpcUrl: string | undefined,
  doFetch: FetchLike = fetch,
): Promise<Response> {
  if (request.method !== "POST") return json({ error: "POST only" }, 405);
  if (!rpcUrl) return json({ error: "rpc unavailable (no keyed endpoint configured)" }, 503);

  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return json({ error: "too large" }, 413);
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return json({ error: "bad json" }, 400);
  }

  // Single request or a JSON-RPC batch — every method must be read-only.
  const reqs = Array.isArray(parsed) ? parsed : [parsed];
  if (reqs.length === 0) return json({ error: "empty batch" }, 400);
  if (reqs.length > MAX_BATCH) return json({ error: "batch too large" }, 413);
  for (const r of reqs) {
    const m = (r as { method?: unknown })?.method;
    if (typeof m !== "string" || !READ_METHODS.has(m)) {
      return json({ error: `method not allowed: ${typeof m === "string" ? m : "?"}` }, 403);
    }
  }

  let upstream: Response;
  try {
    upstream = await doFetch(rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // Forward OUR re-serialization of the validated parse, never the attacker's raw bytes. Raw
      // forwarding lets a duplicate `method` key ({"method":"eth_sendRawTransaction","method":"eth_call"})
      // pass the last-wins JSON.parse allowlist check while a first-wins upstream parser executes the
      // smuggled write. Serializing `parsed` collapses the object to its single parsed value.
      body: JSON.stringify(parsed),
    });
  } catch {
    return json({ error: "rpc upstream failed (network)" }, 502);
  }
  const out = await upstream.text();
  return new Response(out, {
    status: upstream.status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
