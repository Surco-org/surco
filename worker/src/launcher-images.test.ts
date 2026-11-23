import { describe, expect, it } from "vitest";
import {
  detectImageType,
  handleImageGet,
  handleImageUpload,
  handleMetaGet,
  handleMetaUpload,
  MAX_IMAGE_BYTES,
  type R2BucketLike,
} from "./launcher-images";

function mockBucket(): R2BucketLike & { store: Map<string, { bytes: Uint8Array<ArrayBuffer>; contentType?: string }> } {
  const store = new Map<string, { bytes: Uint8Array<ArrayBuffer>; contentType?: string }>();
  return {
    store,
    async put(key, value, opts) {
      const copy = new Uint8Array(new ArrayBuffer(value.byteLength));
      copy.set(value instanceof Uint8Array ? value : new Uint8Array(value));
      store.set(key, { bytes: copy, contentType: opts?.httpMetadata?.contentType });
    },
    async get(key) {
      const hit = store.get(key);
      if (!hit) return null;
      return {
        body: hit.bytes,
        httpMetadata: { contentType: hit.contentType },
        async arrayBuffer() {
          return hit.bytes.buffer.slice(hit.bytes.byteOffset, hit.bytes.byteOffset + hit.bytes.byteLength);
        },
      };
    },
  };
}

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52]);
const JPG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1]);
const WEBP = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0x24, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20]);
const SVG = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');

describe("launcher-images", () => {
  it("detects PNG, JPEG, and WebP magic bytes and rejects SVG/HTML/tiny inputs", () => {
    expect(detectImageType(PNG)).toEqual({ ext: "png", mime: "image/png" });
    expect(detectImageType(JPG)).toEqual({ ext: "jpg", mime: "image/jpeg" });
    expect(detectImageType(WEBP)).toEqual({ ext: "webp", mime: "image/webp" });
    expect(detectImageType(SVG)).toBeNull();
    expect(detectImageType(new Uint8Array([0x89, 0x50, 0x4e]))).toBeNull();
  });

  it("uploads a valid PNG, deduplicates by sha256, and serves it with immutable + nosniff headers", async () => {
    const bucket = mockBucket();
    const req = new Request("https://surcofi.com/api/launcher/image", { method: "POST", body: PNG });
    const res = await handleImageUpload(req, bucket, "https://surcofi.com");
    expect(res.status).toBe(201);
    const body = (await res.json()) as { key: string; url: string; mime: string; bytes: number };
    expect(body.key).toMatch(/^[0-9a-f]{64}\.png$/);
    expect(body.url).toBe(`https://surcofi.com/api/launcher/image/${body.key}`);
    expect(body.mime).toBe("image/png");
    expect(body.bytes).toBe(PNG.length);

    const getRes = await handleImageGet(body.key, bucket);
    expect(getRes.status).toBe(200);
    expect(getRes.headers.get("content-type")).toBe("image/png");
    expect(getRes.headers.get("x-content-type-options")).toBe("nosniff");
    expect(getRes.headers.get("cache-control")).toContain("immutable");
    const got = new Uint8Array(await getRes.arrayBuffer());
    expect(got).toEqual(PNG);
  });

  it("rejects SVG even if Content-Type claims image/png", async () => {
    const bucket = mockBucket();
    const req = new Request("https://surcofi.com/api/launcher/image", {
      method: "POST",
      headers: { "content-type": "image/png" },
      body: SVG,
    });
    const res = await handleImageUpload(req, bucket, "https://surcofi.com");
    expect(res.status).toBe(415);
    expect(bucket.store.size).toBe(0);
  });

  it("rejects payloads over MAX_IMAGE_BYTES", async () => {
    const bucket = mockBucket();
    const big = new Uint8Array(MAX_IMAGE_BYTES + 1);
    big.set(PNG, 0);
    const req = new Request("https://surcofi.com/api/launcher/image", { method: "POST", body: big });
    const res = await handleImageUpload(req, bucket, "https://surcofi.com");
    expect(res.status).toBe(413);
    expect(bucket.store.size).toBe(0);
  });

  it("rejects path traversal and invalid keys on GET", async () => {
    const bucket = mockBucket();
    expect((await handleImageGet("../secret.png", bucket)).status).toBe(404);
    expect((await handleImageGet("bad.svg", bucket)).status).toBe(404);
    expect((await handleImageGet(`${"a".repeat(64)}.png`, bucket)).status).toBe(404);
  });

  it("returns 503 when R2 binding is absent", async () => {
    const req = new Request("https://surcofi.com/api/launcher/image", { method: "POST", body: PNG });
    expect((await handleImageUpload(req, undefined, "https://surcofi.com")).status).toBe(503);
    expect((await handleImageGet(`${"a".repeat(64)}.png`, undefined)).status).toBe(503);
  });

  it("uploads Broker-Cat + ERC-7572 JSON metadata and serves it with open CORS", async () => {
    const bucket = mockBucket();
    const req = new Request("https://surcofi.com/api/launcher/meta", {
      method: "POST",
      body: JSON.stringify({
        name: "Barn Owl",
        symbol: "OWL",
        description: "Pinto backed owl.",
        image: "https://surcofi.com/api/launcher/image/abc.png",
        website: "https://barnowl.xyz",
        twitter: "https://x.com/barnowl",
      }),
    });
    const res = await handleMetaUpload(req, bucket, "https://surcofi.com");
    expect(res.status).toBe(201);
    const body = (await res.json()) as { key: string; url: string; meta: Record<string, unknown> };
    expect(body.key).toMatch(/^[0-9a-f]{64}\.json$/);
    expect(body.url).toBe(`https://surcofi.com/api/launcher/meta/${body.key}`);
    expect(body.meta.external_link).toBe("https://barnowl.xyz/");
    expect(body.meta.website).toBe("https://barnowl.xyz/");
    expect(body.meta.links).toEqual({ website: "https://barnowl.xyz/", twitter: "https://x.com/barnowl" });
    expect(body.meta.createdOn).toBe("https://surcofi.com");

    const getRes = await handleMetaGet(body.key, bucket);
    expect(getRes.status).toBe(200);
    expect(getRes.headers.get("access-control-allow-origin")).toBe("*");
    expect(getRes.headers.get("content-type")).toContain("application/json");
  });

  it("rejects javascript: or http: website URLs on metadata upload", async () => {
    const bucket = mockBucket();
    const bad = new Request("https://surcofi.com/api/launcher/meta", {
      method: "POST",
      body: JSON.stringify({ name: "Bad", symbol: "BAD", website: "javascript:alert(1)" }),
    });
    expect((await handleMetaUpload(bad, bucket, "https://surcofi.com")).status).toBe(400);
  });
});
