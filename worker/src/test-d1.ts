// Test-only: a real SQLite (node:sqlite, Node 22) behind the D1Like shape, with the chirp migrations applied,
// so the indexer's SQL is exercised for real instead of by string matching.
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import type { D1Like } from "./chirp";

const DIR = new URL("../migrations/", import.meta.url);

export function testDb(): D1Like & { raw: DatabaseSync } {
  const raw = new DatabaseSync(":memory:");
  for (const f of readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort()) raw.exec(readFileSync(new URL(f, DIR), "utf8"));
  const prepare = (sql: string) => {
    let args: unknown[] = [];
    const stmt = {
      bind: (...a: unknown[]) => ((args = a), stmt),
      first: async <T,>() => (raw.prepare(sql).get(...(args as never[])) ?? null) as T | null,
      all: async <T,>() => ({ results: raw.prepare(sql).all(...(args as never[])) as T[] }),
      run: async () => ({ meta: { changes: Number(raw.prepare(sql).run(...(args as never[])).changes) } }),
    };
    return stmt;
  };
  return {
    raw,
    prepare,
    // D1 runs a batch as one transaction: all or nothing.
    batch: async (stmts) => {
      raw.exec("BEGIN");
      try {
        const out = [];
        for (const s of stmts) out.push(await s.run());
        raw.exec("COMMIT");
        return out;
      } catch (e) {
        raw.exec("ROLLBACK");
        throw e;
      }
    },
  };
}
