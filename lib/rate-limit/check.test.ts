import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { SupabaseClient } from "@supabase/supabase-js";

import { limiterClient } from "./check";
import { visitorAddress } from "./limits";

const named = (name: string) => ({ name }) as unknown as SupabaseClient;

describe("the limiter counts with the service key, not the caller's session", () => {
  it("uses the service key when the site has one", () => {
    const made: string[] = [];
    const client = limiterClient(named("caller"), { SUPABASE_URL: "https://db.example", SUPABASE_SERVICE_ROLE_KEY: "k1" }, (url, key) => {
      made.push(`${url} ${key}`);
      return named("service");
    });
    assert.equal((client as unknown as { name: string }).name, "service");
    assert.deepEqual(made, ["https://db.example k1"]);
  });

  it("falls back to the caller's client only when no service key is set", () => {
    const client = limiterClient(named("caller"), { SUPABASE_URL: "https://db.example" }, () => named("service"));
    assert.equal((client as unknown as { name: string }).name, "caller");
  });

  it("keeps one service client per key instead of making one per request", () => {
    let count = 0;
    const env = { NEXT_PUBLIC_SUPABASE_URL: "https://db.example", SUPABASE_SERVICE_ROLE_KEY: "k2" };
    const make = () => {
      count += 1;
      return named("service");
    };
    limiterClient(named("a"), env, make);
    limiterClient(named("b"), env, make);
    assert.equal(count, 1);
  });
});

describe("a per-address limit is keyed on the visitor, not on the CDN machine they came through", () => {
  const h = (init: Record<string, string>) => new Headers(init);

  it("takes the address the proxy copied in, over the forwarded-for the proxy overwrites", () => {
    assert.equal(visitorAddress(h({ "x-real-ip": "203.0.113.7", "x-forwarded-for": "172.70.1.1" })), "203.0.113.7");
  });

  it("two visitors through the same CDN machine get different keys", () => {
    const a = visitorAddress(h({ "x-real-ip": "203.0.113.7", "x-forwarded-for": "172.70.1.1" }));
    const b = visitorAddress(h({ "x-real-ip": "198.51.100.9", "x-forwarded-for": "172.70.1.1" }));
    assert.notEqual(a, b);
  });

  it("falls back in order when the proxy's header is missing", () => {
    assert.equal(visitorAddress(h({ "cf-connecting-ip": "203.0.113.8", "x-forwarded-for": "172.70.1.1" })), "203.0.113.8");
    assert.equal(visitorAddress(h({ "x-forwarded-for": "192.0.2.4, 10.0.0.1" })), "192.0.2.4");
    assert.equal(visitorAddress(h({})), "0.0.0.0");
  });

  it("an empty header is not an address", () => {
    assert.equal(visitorAddress(h({ "x-real-ip": "  ", "x-forwarded-for": "192.0.2.4" })), "192.0.2.4");
  });
});
