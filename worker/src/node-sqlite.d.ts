// Node 22's built-in SQLite, used only by test-d1.ts. @types/node here is v20 and predates it.
// ponytail: hand typing for the four calls used; drop this file when @types/node ≥ 22.5.
declare module "node:sqlite" {
  type Row = Record<string, unknown>;
  interface StatementSync {
    get(...args: unknown[]): Row | undefined;
    all(...args: unknown[]): Row[];
    run(...args: unknown[]): { changes: number | bigint };
  }
  export class DatabaseSync {
    constructor(path: string);
    exec(sql: string): void;
    prepare(sql: string): StatementSync;
  }
}
