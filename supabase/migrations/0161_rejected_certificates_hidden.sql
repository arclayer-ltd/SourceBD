-- 0161 — A certificate an admin rejected is no longer shown to buyers or visitors (#651).
--
-- THE FAULT
--   An admin rejects a certificate by stamping `rejected_at` on its row (0039); the row stays so the admin
--   queue can show the decision. Search (0104), the expired-certificates list (0108) and evidence packs
--   (0114) leave such a row out. Every other reader a buyer or visitor reaches did not:
--     * buyer_supplier_profile()          the certificates list on the supplier's page, company and buildings
--     * v_supplier_registry_ids_direct     the "GOTS Cert #…" pill on the same page and on cards
--     * compliance_expiring_certs()        the compliance hub's expiring list
--     * compliance_msa_inputs()            the Modern Slavery statement's certificate counts
--     * buyer_dashboard()                  the expiring alerts and the "certificate added/expired" feed
--     * buyer_smart_match()                the certificate a match is said to hold
--   A rejected certificate shown as held is a false receipt.
--
-- WHAT THIS DOES
--   Each reader gains `rejected_at is null` beside its join to the certificate. Each is edited in place
--   from the text the database holds, never from an older copy in this repo (production's functions have
--   run ahead of the files before: see 0105). Every edit must find its text the expected number of times
--   or the migration stops with nothing changed.
--
-- REVERSE
--   The same block with each pair's old and new text swapped.

do $$
declare
  e   record;
  def text;
  n   int;
  pat constant text := '(join public\.certifications c\s+on c\.supplier_id = [sf]\.id)\M';
begin
  -- 1. The registry pill.
  def := pg_get_viewdef('public.v_supplier_registry_ids_direct'::regclass, true);
  if (length(def) - length(replace(def, $o$btrim(c.certificate_no) <> ''::text$o$, '')))
       / length($o$btrim(c.certificate_no) <> ''::text$o$) <> 1 then
    raise exception '0161: the certificate branch of v_supplier_registry_ids_direct is not the text expected';
  end if;
  execute 'create or replace view public.v_supplier_registry_ids_direct as '
    || replace(def, $o$btrim(c.certificate_no) <> ''::text$o$,
                    $n$btrim(c.certificate_no) <> ''::text AND c.rejected_at IS NULL$n$);

  -- 2. The readers that join a certificate as `c` to a supplier `s` (or a building `f`).
  for e in
    select * from (values
      ('buyer_supplier_profile',    2),
      ('compliance_expiring_certs', 1),
      ('compliance_msa_inputs',     2),
      ('buyer_dashboard',           3)
    ) v(fn, expected)
  loop
    if (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname = 'public' and p.proname = e.fn) <> 1 then
      raise exception '0161: public.% is not one function', e.fn;
    end if;
    def := pg_get_functiondef(('public.' || e.fn)::regproc);
    n := (select count(*) from regexp_matches(def, pat, 'g'));
    if n <> e.expected then
      raise exception '0161: % joins a certificate % times, expected %', e.fn, n, e.expected;
    end if;
    execute regexp_replace(def, pat, '\1 and c.rejected_at is null', 'g');
  end loop;

  -- 3. The match reason, which names its certificate `cert`.
  def := pg_get_functiondef('public.buyer_smart_match'::regproc);
  if (length(def) - length(replace(def, 'where cert.supplier_id = r.id', '')))
       / length('where cert.supplier_id = r.id') <> 1 then
    raise exception '0161: buyer_smart_match does not hold its certificate join exactly once';
  end if;
  execute replace(def, 'where cert.supplier_id = r.id',
                       'where cert.supplier_id = r.id and cert.rejected_at is null');
end $$;

notify pgrst, 'reload schema';
