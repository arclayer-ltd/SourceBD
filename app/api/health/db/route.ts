// Readiness probe: 200 only when this server can read the database. The deploy waits on it, so a
// release whose site cannot reach Supabase fails the deploy instead of passing it.
//
// `/api/health` stays the liveness probe (no database call): Docker's healthcheck uses it, and a
// database outage should not mark the process itself dead.
//
// The read is a head request on `profiles` with the public anon key: it returns no rows (row security
// hides them all from anon, and `head` asks for none), but it reaches Postgres, which a request the API
// gateway can answer from its own cache would not. The response says only ok or not, and the commit.

import { createClient } from "@supabase/supabase-js";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const TIMEOUT_MS = 5000;

export async function GET() {
  const commit = process.env.COMMIT_SHA ?? process.env.VERCEL_GIT_COMMIT_SHA ?? "unknown";
  const url = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  let failure: string | null = "database settings missing";
  if (url && key) {
    try {
      const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
      const { error } = await db
        .from("profiles")
        .select("id", { head: true })
        .limit(1)
        .abortSignal(AbortSignal.timeout(TIMEOUT_MS));
      failure = error ? error.message || "request refused" : null;
    } catch (err) {
      failure = err instanceof Error ? err.message : String(err);
    }
  }
  if (failure) {
    console.error(`[health/db] database unreachable: ${failure}`);
    return Response.json({ status: "error", db: "unreachable", commit }, { status: 503 });
  }
  return Response.json({ status: "ok", db: "ok", commit });
}
