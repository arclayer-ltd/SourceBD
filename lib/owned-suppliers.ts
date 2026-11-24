import type { createSupabaseServerClient } from "@/lib/supabase/server";

type Sb = Awaited<ReturnType<typeof createSupabaseServerClient>>;

/**
 * The published companies the signed-in caller has claimed, by name. `null` when either read fails, so a
 * page can say it could not load them rather than "you haven't claimed any".
 *
 * Who claimed a supplier (`suppliers.claimed_by`) is not readable by signed-in users (REZ-22), so a
 * `.eq("claimed_by", uid)` read is refused and every claimant saw an empty portal (#644). The database
 * answers the question instead: `claimed_supplier_ids()` returns the caller's own ids and nothing else.
 */
export async function readOwnedSuppliers<T>(supabase: Sb, columns: string): Promise<T[] | null> {
  const ids = await supabase.rpc("claimed_supplier_ids");
  if (ids.error) return null;
  const owned = (ids.data as string[] | null) ?? [];
  if (owned.length === 0) return [];
  const { data, error } = await supabase
    .from("suppliers")
    .select(columns)
    .in("id", owned)
    .eq("is_published", true)
    .order("company_name");
  if (error) return null;
  return (data ?? []) as T[];
}
