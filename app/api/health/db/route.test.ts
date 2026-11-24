// The deploy's post-release check reads /api/health/db. It must fail when the site cannot reach its
// database, and pass with the deployed commit when it can. The database is faked at globalThis.fetch,
// which postgrest-js calls per request, so nothing leaves the process.

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import { GET } from "./route";

const ENV_KEYS = [
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "COMMIT_SHA",
] as const;

const realFetch = globalThis.fetch;
const realConsoleError = console.error;
let savedEnv: Record<string, string | undefined> = {};
let requests: { url: string; method: string }[] = [];

function database(answer: () => Response | Promise<Response>): void {
  globalThis.fetch = (async (input: unknown, init?: { method?: string }) => {
    const url = typeof input === "string" ? input : (input as { url: string }).url;
    requests.push({ url, method: init?.method ?? "GET" });
    return answer();
  }) as typeof fetch;
}

describe("GET /api/health/db", () => {
  beforeEach(() => {
    savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
    for (const k of ENV_KEYS) delete process.env[k];
    process.env.SUPABASE_URL = "https://supabase.invalid";
    process.env.SUPABASE_ANON_KEY = "anon-key";
    process.env.COMMIT_SHA = "abc1234";
    requests = [];
    console.error = () => {};
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
    console.error = realConsoleError;
    for (const k of ENV_KEYS) {
      if (savedEnv[k] === undefined) delete process.env[k];
      else process.env[k] = savedEnv[k];
    }
  });

  it("is 200 with the commit when the database answers", async () => {
    database(() => new Response(null, { status: 200 }));
    const res = await GET();
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: "ok", db: "ok", commit: "abc1234" });
    assert.equal(requests.length, 1);
    assert.equal(requests[0]!.method, "HEAD");
    assert.match(requests[0]!.url, /^https:\/\/supabase\.invalid\/rest\/v1\/profiles\?/);
  });

  it("is 503 when the database cannot be reached", async () => {
    database(() => {
      throw new TypeError("fetch failed");
    });
    const res = await GET();
    assert.equal(res.status, 503);
    assert.deepEqual(await res.json(), { status: "error", db: "unreachable", commit: "abc1234" });
  });

  it("is 503 when the database refuses the request", async () => {
    database(() => new Response(null, { status: 401, statusText: "Unauthorized" }));
    const res = await GET();
    assert.equal(res.status, 503);
  });

  it("is 503, without calling out, when the database settings are missing", async () => {
    delete process.env.SUPABASE_URL;
    delete process.env.SUPABASE_ANON_KEY;
    database(() => new Response(null, { status: 200 }));
    const res = await GET();
    assert.equal(res.status, 503);
    assert.equal(requests.length, 0);
  });
});
