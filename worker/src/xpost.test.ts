import { describe, it, expect } from "vitest";
import { oauthHeader, postTweet, type XKeys } from "./xpost";

// X's "Creating a signature" documentation example.
const DOC_KEYS: XKeys = {
  apiKey: "xvz1evFS4wEEPTGEFPHBog",
  apiSecret: "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw",
  token: "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb",
  tokenSecret: "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE",
};

describe("oauthHeader", () => {
  it("signs X's documented example", async () => {
    const h = await oauthHeader(
      "POST",
      "https://api.twitter.com/1.1/statuses/update.json",
      { include_entities: "true", status: "Hello Ladies + Gentlemen, a signed OAuth request!" },
      DOC_KEYS,
      "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg",
      "1318622958",
    );
    expect(h.startsWith("OAuth ")).toBe(true);
    expect(h).toContain('oauth_signature="hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D"');
    expect(h).toContain('oauth_consumer_key="xvz1evFS4wEEPTGEFPHBog"');
  });
});

describe("postTweet", () => {
  it("posts JSON text with an OAuth header", async () => {
    let seen: { url: string; init: RequestInit } | undefined;
    const fake = (async (url: string, init: RequestInit) => {
      seen = { url, init };
      return new Response(JSON.stringify({ data: { id: "123" } }), { status: 201 });
    }) as unknown as typeof fetch;
    const r = await postTweet("hi", DOC_KEYS, fake);
    expect(r).toEqual({ ok: true, status: 201, id: "123" });
    expect(seen!.url).toBe("https://api.x.com/2/tweets");
    expect(seen!.init.method).toBe("POST");
    expect(seen!.init.body).toBe('{"text":"hi"}');
    const headers = new Headers(seen!.init.headers);
    expect(headers.get("authorization")!.startsWith("OAuth ")).toBe(true);
    expect(headers.get("content-type")).toBe("application/json");
    expect(seen!.init.signal).toBeInstanceOf(AbortSignal); // a hung X call cannot stretch the cron run
  });

  it("non-2xx is ok:false and carries X's reason", async () => {
    const fake = (async () => new Response('{"title":"Forbidden","detail":"not permitted"}', { status: 403 })) as unknown as typeof fetch;
    expect(await postTweet("hi", DOC_KEYS, fake)).toEqual({ ok: false, status: 403, error: '{"title":"Forbidden","detail":"not permitted"}' });
  });
});
