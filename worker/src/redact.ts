// Render an error for logging with every configured secret scrubbed. viem transport errors embed the
// full request URL — including the API key in the path/query — in their message, and console.error(e)
// is visible in `wrangler tail`. Scrub each secret before it ever reaches a log line. Variadic so the
// invariant isn't "only RPC_URL is safe to log": pass the RPC URL, 0x key, telegram token — anything
// that could surface in an upstream error string.

export function safeErr(e: unknown, ...secrets: (string | undefined)[]): string {
  let s: string;
  try {
    s = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
  } catch {
    s = "unstringifiable error";
  }
  for (const secret of secrets) {
    // The truthy guard also rejects the empty string, so we never split on "" (which would explode s).
    if (secret) s = s.split(secret).join("[secret redacted]");
  }
  return s;
}
