-- 0160: functions a signed-out visitor has no reason to call are closed to signed-out visitors.
--
-- Every function here already checked its caller inside, or was read-only. This takes away the
-- permission to call them at all, so that the check inside is the second line and not the only one.
--
--   * Every admin function (admin_*, feedback_admin_*, claim_admin_*): signed-in callers only. The
--     function itself still decides whether that caller is an admin.
--   * Three internal helpers the website never calls directly (supplier_search_candidates,
--     rsc_workers_batch, recompute_t13_source_count): the service role only. The functions and
--     triggers that use them run as their owner and are unaffected.
--   * A debugging function left in production by hand, never in this repository: dropped.
--
-- What a public page reads (the supplier profile, search, the facts in the footer) is untouched;
-- assert-0160.sql holds both halves.
--
-- Safe on a live database: permissions only, no row touched. Safe to run twice.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and (p.proname like 'admin\_%' or p.proname like 'feedback\_admin\_%' or p.proname like 'claim\_admin\_%')
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
  end loop;

  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('supplier_search_candidates', 'rsc_workers_batch', 'recompute_t13_source_count')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

drop function if exists public._b6_authdebug();
