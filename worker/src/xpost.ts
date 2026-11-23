// Posts to X as @chirpfi: OAuth 1.0a user context (static tokens), HMAC-SHA1 via WebCrypto, POST /2/tweets.
// A JSON body is not part of the signature, so postTweet signs no extra params.
export type XKeys = { apiKey: string; apiSecret: string; token: string; tokenSecret: string };

const enc = (s: string) => encodeURIComponent(s).replace(/[!*'()]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

export async function oauthHeader(
  method: string,
  url: string,
  params: Record<string, string>,
  k: XKeys,
  nonce: string,
  timestamp: string,
): Promise<string> {
  const oauth: Record<string, string> = {
    oauth_consumer_key: k.apiKey,
    oauth_nonce: nonce,
    oauth_signature_method: "HMAC-SHA1",
    oauth_timestamp: timestamp,
    oauth_token: k.token,
    oauth_version: "1.0",
  };
  const all = { ...params, ...oauth };
  const paramStr = Object.keys(all)
    .map((key) => [enc(key), enc(all[key])])
    .sort(([a, x], [b, y]) => (a < b ? -1 : a > b ? 1 : x < y ? -1 : x > y ? 1 : 0))
    .map(([key, v]) => `${key}=${v}`)
    .join("&");
  const base = `${method.toUpperCase()}&${enc(url)}&${enc(paramStr)}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`${enc(k.apiSecret)}&${enc(k.tokenSecret)}`),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(base)));
  const b64 = btoa(String.fromCharCode(...sig));
  const fields = { ...oauth, oauth_signature: b64 };
  return "OAuth " + Object.keys(fields).sort().map((f) => `${enc(f)}="${enc(fields[f as keyof typeof fields])}"`).join(", ");
}

const TWEETS = "https://api.x.com/2/tweets";

export async function postTweet(text: string, k: XKeys, fetchFn: typeof fetch = fetch): Promise<{ ok: boolean; status: number; id?: string; error?: string }> {
  const nonce = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
  const auth = await oauthHeader("POST", TWEETS, {}, k, nonce, String(Math.floor(Date.now() / 1000)));
  const res = await fetchFn(TWEETS, {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify({ text }),
    // A hung X call must not stretch the cron run (overlapping runs could exceed the daily cap). Abort → the
    // caller marks the post failed.
    signal: AbortSignal.timeout(10_000),
  });
  // X's error body (JSON title/detail) says why: bad keys, read-only token, no credits. No secret is in it.
  if (!res.ok) return { ok: false, status: res.status, error: (await res.text().catch(() => "")).slice(0, 300) };
  const id = ((await res.json().catch(() => null)) as { data?: { id?: string } } | null)?.data?.id;
  return id ? { ok: true, status: res.status, id } : { ok: true, status: res.status };
}
