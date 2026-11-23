-- 0160 asserted: a signed-out visitor may call no admin function and none of the three internal
-- helpers; a signed-in caller may still reach the admin functions (which decide for themselves);
-- and the functions a public page reads are still open to visitors.
\set ON_ERROR_STOP on

do $$
declare
  bad text;
begin
  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and (p.proname like 'admin\_%' or p.proname like 'feedback\_admin\_%' or p.proname like 'claim\_admin\_%')
     and has_function_privilege('anon', p.oid, 'execute');
  if bad is not null then
    raise exception '0160: a visitor can call admin functions: %', bad;
  end if;

  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('supplier_search_candidates', 'rsc_workers_batch', 'recompute_t13_source_count')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  if bad is not null then
    raise exception '0160: internal helpers are callable from outside: %', bad;
  end if;

  if not has_function_privilege('authenticated', 'public.admin_dashboard()', 'execute') then
    raise exception '0160: a signed-in caller can no longer reach admin_dashboard';
  end if;

  select string_agg(p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('buyer_supplier_profile', 'discover_suppliers', 'discover_facets', 'marketing_facts',
                       'facility_parent_slug', 'production_workers_display_batch')
     and not has_function_privilege('anon', p.oid, 'execute');
  if bad is not null then
    raise exception '0160: a public page lost a function it reads: %', bad;
  end if;
end $$;
