import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { handleRpcProxy, MAX_BATCH } from "./rpc";

describe("worker wiring", () => {
  it("routes /api/rpc through the rate limiter to handleRpcProxy with the keyed RPC_URL", () => {
    const src = readFileSync(fileURLToPath(new URL("./index.ts", import.meta.url)), "utf8");
    expect(src).toContain('url.pathname === "/api/rpc"');
    expect(src).toContain("env.RPC_LIMITER.limit");
    expect(src).toContain("handleRpcProxy(request, env.RPC_URL)");
  });
});

const post = (body: unknown) =>
  new Request("https://x/api/rpc", { method: "POST", body: JSON.stringify(body) });

function fakeUpstream(captured: { url?: string; body?: string }) {
  return (async (url: string, init?: { body?: string }) => {
    captured.url = String(url);
    captured.body = init?.body;
    return { ok: true, status: 200, text: async () => '{"jsonrpc":"2.0","id":1,"result":"0x1"}' };
  }) as unknown as typeof fetch;
}

const RPC = "https://keyed.example/v2/SECRET";

describe("handleRpcProxy", () => {
  it("forwards a read method to the keyed upstream and returns its body", async () => {
    const cap: { url?: string; body?: string } = {};
    const res = await handleRpcProxy(post({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [] }), RPC, fakeUpstream(cap));
    expect(res.status).toBe(200);
    expect(cap.url).toBe(RPC); // forwarded to the keyed endpoint, key never seen by the browser
    expect(await res.text()).toContain("0x1");
  });

  it("allows a one-element batch of a read method", async () => {
    const res = await handleRpcProxy(post([{ jsonrpc: "2.0", id: 1, method: "eth_call", params: [] }]), RPC, fakeUpstream({}));
    expect(res.status).toBe(200);
  });

  it("refuses the costly reads /app never sends (eth_getLogs, eth_estimateGas) with 403", async () => {
    for (const method of ["eth_getLogs", "eth_estimateGas", "eth_feeHistory"]) {
      const res = await handleRpcProxy(post({ jsonrpc: "2.0", id: 1, method, params: [] }), RPC, fakeUpstream({}));
      expect(res.status).toBe(403);
    }
  });

  it("blocks a write method (eth_sendRawTransaction) with 403", async () => {
    let called = false;
    const doFetch = (async () => { called = true; return { ok: true, status: 200, text: async () => "" }; }) as unknown as typeof fetch;
    const res = await handleRpcProxy(post({ jsonrpc: "2.0", id: 1, method: "eth_sendRawTransaction", params: ["0xabc"] }), RPC, doFetch);
    expect(res.status).toBe(403);
    expect(called).toBe(false); // never reached the upstream
  });

  it("blocks a batch whose method is not a read", async () => {
    const res = await handleRpcProxy(post([{ jsonrpc: "2.0", id: 1, method: "eth_sendTransaction", params: [] }]), RPC, fakeUpstream({}));
    expect(res.status).toBe(403);
  });

  it("405 on non-POST", async () => {
    const res = await handleRpcProxy(new Request("https://x/api/rpc", { method: "GET" }), RPC);
    expect(res.status).toBe(405);
  });

  it("503 when no keyed RPC is configured", async () => {
    const res = await handleRpcProxy(post({ jsonrpc: "2.0", id: 1, method: "eth_call" }), undefined);
    expect(res.status).toBe(503);
  });

  it("400 on bad JSON", async () => {
    const res = await handleRpcProxy(new Request("https://x/api/rpc", { method: "POST", body: "not json" }), RPC);
    expect(res.status).toBe(400);
  });

  it("413 on an oversized batch (quota-amplification guard)", async () => {
    let called = false;
    const doFetch = (async () => { called = true; return { ok: true, status: 200, text: async () => "" }; }) as unknown as typeof fetch;
    const batch = Array.from({ length: MAX_BATCH + 1 }, (_, i) => ({ jsonrpc: "2.0", id: i, method: "eth_call", params: [] }));
    const res = await handleRpcProxy(post(batch), RPC, doFetch);
    expect(res.status).toBe(413);
    expect(called).toBe(false); // never reached the upstream — one POST can't fan out to N upstream calls
  });

  it("forwards the re-serialized validated JSON, not the attacker's raw bytes (duplicate-key smuggle)", async () => {
    // JSON.parse keeps the last "method" (eth_call, allowed); a first-wins upstream parser must never
    // see the smuggled eth_sendRawTransaction. We forward our own serialization, so it can't.
    const cap: { url?: string; body?: string } = {};
    const raw = '{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","method":"eth_call","params":[]}';
    const req = new Request("https://x/api/rpc", { method: "POST", body: raw });
    const res = await handleRpcProxy(req, RPC, fakeUpstream(cap));
    expect(res.status).toBe(200);
    expect(cap.body).not.toContain("eth_sendRawTransaction"); // the smuggled key is gone
  });
});
