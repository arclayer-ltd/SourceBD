// The limiter. Wraps the `public.rl_check` database function.
//
// The count is taken with the service key, so it does not depend on what the caller's own session
// is allowed to call. A failed call lets the request through, so that a database outage does not
// lock every user out.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export type RateLimitResult = { ok: boolean; retryAfter: number };

type RlCheckEnvelope = {
  ok: boolean;
  retry_after_seconds: number;
};

type Env = Record<string, string | undefined>;
type MakeClient = (url: string, key: string) => SupabaseClient;

const makeServiceClient: MakeClient = (url, key) =>
  createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

let cached: { url: string; key: string; client: SupabaseClient } | null = null;

/**
 * The client the limiter counts with: the service key when the site has one, otherwise the
 * caller's (local development without a service key). One client is kept per key.
 */
export function limiterClient(
  fallback: SupabaseClient,
  env: Env = process.env,
  make: MakeClient = makeServiceClient,
): SupabaseClient {
  const url = env.SUPABASE_URL || env.NEXT_PUBLIC_SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return fallback;
  if (!cached || cached.url !== url || cached.key !== key) {
    cached = { url, key, client: make(url, key) };
  }
  return cached.client;
}

export async function rlCheck(
  supabase: SupabaseClient,
  bucket: string,
  ident: string,
  limitPerMin: number,
): Promise<RateLimitResult> {
  const { data, error } = await limiterClient(supabase).rpc("rl_check", {
    p_bucket: bucket,
    p_ident: ident,
    p_limit_per_min: limitPerMin,
  });
  if (error || !data) return { ok: true, retryAfter: 0 };
  const env = data as RlCheckEnvelope;
  return {
    ok: env.ok === true,
    retryAfter: Math.max(0, Number(env.retry_after_seconds) || 0),
  };
}
