// R2-backed coin image upload & serving for the launcher (/api/launcher/image).
// Validates magic bytes (PNG, JPEG, WebP only — never SVG), enforces a 512 KB cap, and stores
// objects content-addressed by SHA-256 so repeated uploads deduplicate cleanly.

export const MAX_IMAGE_BYTES = 512 * 1024; // 512 KB
export const MAX_META_BYTES = 4 * 1024; // 4 KB JSON metadata document

export type R2ObjectLike = {
  body: ReadableStream | Uint8Array<ArrayBuffer> | ArrayBuffer | null;
  httpMetadata?: { contentType?: string };
  arrayBuffer(): Promise<ArrayBuffer>;
};

export type R2BucketLike = {
  get(key: string): Promise<R2ObjectLike | null>;
  put(
    key: string,
    value: ArrayBuffer | Uint8Array<ArrayBuffer>,
    options?: { httpMetadata?: { contentType?: string; cacheControl?: string } },
  ): Promise<unknown>;
};

export type DetectedImage = { ext: "png" | "jpg" | "webp"; mime: "image/png" | "image/jpeg" | "image/webp" };

/** Inspects file header magic bytes. Rejects SVG, HTML, GIF, ICO, or any unknown binary. */
export function detectImageType(bytes: Uint8Array): DetectedImage | null {
  if (bytes.length < 12) return null;
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) {
    return { ext: "png", mime: "image/png" };
  }
  // JPEG: FF D8 FF
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return { ext: "jpg", mime: "image/jpeg" };
  }
  // WebP: "RIFF" .... "WEBP"
  if (
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) {
    return { ext: "webp", mime: "image/webp" };
  }
  return null;
}

const KEY_RE = /^([0-9a-f]{64})\.(png|jpg|webp)$/;
const EXT_MIME: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  webp: "image/webp",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

async function sha256Hex(buf: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", buf);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readBoundedBytes(
  request: Request,
  maxBytes: number,
  tooLargeMsg: string,
): Promise<{ ok: true; bytes: Uint8Array<ArrayBuffer> } | { ok: false; response: Response }> {
  const cl = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(cl) && cl > maxBytes) {
    return { ok: false, response: json({ error: tooLargeMsg }, 413) };
  }
  const reader = request.body?.getReader();
  if (!reader) return { ok: false, response: json({ error: "empty body" }, 400) };
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        return { ok: false, response: json({ error: tooLargeMsg }, 413) };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, response: json({ error: "failed to read upload" }, 400) };
  }
  if (total === 0) return { ok: false, response: json({ error: "empty body" }, 400) };
  const bytes = new Uint8Array(new ArrayBuffer(total));
  let off = 0;
  for (const c of chunks) {
    bytes.set(c, off);
    off += c.byteLength;
  }
  return { ok: true, bytes };
}

/** POST /api/launcher/image — accepts raw image bytes (PNG/JPEG/WebP, ≤ 512 KB), returns hosted URL. */
export async function handleImageUpload(request: Request, bucket: R2BucketLike | undefined, origin: string): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!bucket) return json({ error: "image storage not configured" }, 503);

  const read = await readBoundedBytes(request, MAX_IMAGE_BYTES, `image too large (max ${MAX_IMAGE_BYTES / 1024} KB)`);
  if (!read.ok) return read.response;
  const bytes = read.bytes;
  const total = bytes.byteLength;

  const detected = detectImageType(bytes);
  if (!detected) {
    return json({ error: "unsupported image format — upload PNG, JPEG, or WebP" }, 415);
  }

  const hash = await sha256Hex(bytes);
  const key = `${hash}.${detected.ext}`;
  await bucket.put(key, bytes, {
    httpMetadata: { contentType: detected.mime, cacheControl: "public, max-age=31536000, immutable" },
  });

  const base = origin.replace(/\/$/, "");
  return json({ key, url: `${base}/api/launcher/image/${key}`, mime: detected.mime, bytes: total }, 201);
}

/** GET /api/launcher/image/<sha256>.<ext> — serves the validated image from R2 with immutable caching. */
export async function handleImageGet(key: string, bucket: R2BucketLike | undefined): Promise<Response> {
  const m = KEY_RE.exec(key);
  if (!m) return json({ error: "not found" }, 404);
  if (!bucket) return json({ error: "image storage not configured" }, 503);
  const obj = await bucket.get(key);
  if (!obj) return json({ error: "not found" }, 404);
  const mime = EXT_MIME[m[2]];
  const body = await obj.arrayBuffer();
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": mime,
      "cache-control": "public, max-age=31536000, immutable",
      "x-content-type-options": "nosniff",
    },
  });
}

const META_KEY_RE = /^([0-9a-f]{64})\.json$/;

function cleanHttpsUrl(raw: unknown, maxLen = 256): string {
  if (typeof raw !== "string") return "";
  const s = raw.trim();
  if (!s || s.length > maxLen || /[\u0000-\u001f\u007f\s]/.test(s)) return "";
  try {
    const u = new URL(s);
    if (u.protocol !== "https:") return "";
    return u.toString();
  } catch {
    return "";
  }
}

function cleanImageOrIpfs(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const s = raw.trim();
  if (!s || s.length > 512 || /[\u0000-\u001f\u007f\s]/.test(s)) return "";
  if (s.toLowerCase().startsWith("ipfs://")) {
    const rest = s.slice(7).replace(/^ipfs\//i, "");
    return /^[a-zA-Z0-9]+(?:\/[a-zA-Z0-9._-]+)*$/.test(rest) ? `ipfs://${rest}` : "";
  }
  return cleanHttpsUrl(s, 512);
}

export type CoinMetaDoc = {
  name: string;
  symbol: string;
  description?: string;
  image?: string;
  external_link?: string;
  website?: string;
  links?: { website?: string; twitter?: string };
  createdOn: string;
};

/**
 * POST /api/launcher/meta — validates and stores a Broker-Cat + ERC-7572 compatible JSON metadata
 * document in R2 under `meta/<sha256>.json`, returning its permanent HTTPS URL.
 */
export async function handleMetaUpload(request: Request, bucket: R2BucketLike | undefined, origin: string): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!bucket) return json({ error: "metadata storage not configured" }, 503);

  const read = await readBoundedBytes(request, MAX_META_BYTES, `metadata payload must be 1..${MAX_META_BYTES} bytes`);
  if (!read.ok) return read.response;
  const text = new TextDecoder().decode(read.bytes);
  let input: Record<string, unknown>;
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    input = parsed as Record<string, unknown>;
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const name = typeof input.name === "string" ? input.name.trim().slice(0, 64) : "";
  const symbol = typeof input.symbol === "string" ? input.symbol.trim().slice(0, 16) : "";
  if (!name || !symbol) return json({ error: "name and symbol are required" }, 400);

  const description = typeof input.description === "string" ? input.description.trim().slice(0, 280) : "";
  const image = cleanImageOrIpfs(input.image);
  const website = cleanHttpsUrl(input.website);
  const twitter = cleanHttpsUrl(input.twitter);

  if (typeof input.website === "string" && input.website.trim() && !website) {
    return json({ error: "website must be a valid https:// URL" }, 400);
  }
  if (typeof input.twitter === "string" && input.twitter.trim() && !twitter) {
    return json({ error: "twitter/X link must be a valid https:// URL" }, 400);
  }

  const links: { website?: string; twitter?: string } = {};
  if (website) links.website = website;
  if (twitter) links.twitter = twitter;

  const doc: CoinMetaDoc = {
    name,
    symbol,
    ...(description ? { description } : {}),
    ...(image ? { image } : {}),
    ...(website ? { external_link: website, website } : {}),
    ...(Object.keys(links).length ? { links } : {}),
    createdOn: "https://surcofi.com",
  };

  const payload = JSON.stringify(doc);
  const encoded = new TextEncoder().encode(payload);
  const copy = new Uint8Array(new ArrayBuffer(encoded.byteLength));
  copy.set(encoded);
  const hash = await sha256Hex(copy);
  const key = `${hash}.json`;

  await bucket.put(`meta/${key}`, copy, {
    httpMetadata: { contentType: "application/json; charset=utf-8", cacheControl: "public, max-age=31536000, immutable" },
  });

  const base = origin.replace(/\/$/, "");
  return json({ key, url: `${base}/api/launcher/meta/${key}`, meta: doc }, 201);
}

/** GET /api/launcher/meta/<sha256>.json — serves coin JSON metadata with open CORS for wallets/indexers. */
export async function handleMetaGet(key: string, bucket: R2BucketLike | undefined): Promise<Response> {
  if (!META_KEY_RE.test(key)) return json({ error: "not found" }, 404);
  if (!bucket) return json({ error: "metadata storage not configured" }, 503);
  const obj = await bucket.get(`meta/${key}`);
  if (!obj) return json({ error: "not found" }, 404);
  const body = await obj.arrayBuffer();
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=31536000, immutable",
      "access-control-allow-origin": "*",
      "x-content-type-options": "nosniff",
    },
  });
}

/** Reads an already-stored R2 metadata doc by key (for indexer / coin-meta attachment). */
export async function readStoredMeta(key: string, bucket: R2BucketLike | undefined): Promise<CoinMetaDoc | null> {
  if (!META_KEY_RE.test(key) || !bucket) return null;
  const obj = await bucket.get(`meta/${key}`);
  if (!obj) return null;
  try {
    const text = new TextDecoder().decode(await obj.arrayBuffer());
    return JSON.parse(text) as CoinMetaDoc;
  } catch {
    return null;
  }
}
