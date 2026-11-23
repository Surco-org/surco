import { describe, it, expect } from "vitest";
import { safeErr } from "./redact";

const KEY_URL = "https://base-mainnet.g.alchemy.com/v2/SECRET_KEY_1234";

describe("safeErr", () => {
  it("scrubs the keyed RPC URL out of a viem-style transport error message", () => {
    const e = new Error(`HTTP request failed.\n\nURL: ${KEY_URL}\nDetails: 429`);
    const out = safeErr(e, KEY_URL);
    expect(out).not.toContain("SECRET_KEY_1234");
    expect(out).toContain("[secret redacted]");
  });

  it("scrubs every configured secret, not just the RPC URL", () => {
    const zeroxKey = "0x-live-key-abcdef";
    const tgToken = "123456:AAtelegramBotTokenSecret";
    const e = new Error(`fetch failed for key=${zeroxKey} and bot ${tgToken}`);
    const out = safeErr(e, KEY_URL, zeroxKey, tgToken);
    expect(out).not.toContain(zeroxKey);
    expect(out).not.toContain(tgToken);
  });

  it("tolerates undefined secrets in the variadic list", () => {
    expect(safeErr(new Error("boom"), undefined, undefined)).toContain("boom");
  });

  it("passes the message through when no secret is configured", () => {
    expect(safeErr(new Error("boom"))).toContain("boom");
    expect(safeErr(new Error("boom"), "")).toContain("boom"); // empty secret never splits on ""
  });

  it("stringifies non-Error values", () => {
    expect(safeErr("plain string")).toBe("plain string");
    expect(safeErr(42)).toBe("42");
  });
});
