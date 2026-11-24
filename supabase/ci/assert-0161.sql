-- 0161 asserted by running it: a certificate an admin rejected is shown nowhere a buyer or visitor reads.
-- A company holds a GOTS certificate and a WRAP one an admin rejected; one of its buildings holds a
-- rejected OEKO-TEX one. The supplier's page (its certificates list and its pills), the compliance hub,
-- the Modern Slavery statement inputs, the buyer dashboard and the match reason all carry the GOTS
-- certificate and neither rejected one.
\set ON_ERROR_STOP on

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-00000000a161', 'a-0161@example.invalid', '{"role":"buyer"}'::jsonb)
on conflict do nothing;

insert into public.suppliers (slug, company_name, company_name_norm, city, district, is_published, is_sanctioned)
values
  ('ci-0161-co',   'CI 0161 Knit Ltd', 'ci 0161 knit ltd', 'Dhaka', 'Dhaka', false, false),
  ('ci-0161-unit', 'CI 0161 Unit 2',   'ci 0161 unit 2',   'Dhaka', 'Dhaka', false, false);

update public.suppliers set facility_of = (select id from public.suppliers where slug = 'ci-0161-co')
 where slug = 'ci-0161-unit';

-- Published only once it holds a Tier 1 source (enforce_publish_tier).
insert into public.source_records (supplier_id, source_id, source_tier, source_ref, fields, fetched_at, status)
select sp.id, s.id, s.tier, 'CI-0161-R1', '{"rsc_status_name": "active"}'::jsonb, now(), 'active'::public.evidence_status
  from public.suppliers sp, public.sources s
 where sp.slug = 'ci-0161-co' and s.code = 'RSC';

update public.suppliers set is_published = true where slug = 'ci-0161-co';

insert into public.certifications (supplier_id, kind, certificate_no, expires_on, rejected_at, rejected_reason)
select sp.id, v.kind::public.cert_kind, v.no, current_date + 20, v.rejected_at, v.reason
  from (values
    ('ci-0161-co',   'gots',     'CI-0161-HELD', null::timestamptz, null),
    ('ci-0161-co',   'wrap',     'CI-0161-REJ1', now(),             'forged'),
    ('ci-0161-unit', 'oeko_tex', 'CI-0161-REJ2', now(),             'forged')
  ) v(slug, kind, no, rejected_at, reason)
  join public.suppliers sp on sp.slug = v.slug;

insert into public.saved_suppliers (owner_id, supplier_id)
select '00000000-0000-4000-8000-00000000a161', id from public.suppliers where slug = 'ci-0161-co';

do $$
declare
  co  uuid := (select id from public.suppliers where slug = 'ci-0161-co');
  got jsonb;
  txt text;
begin
  -- The supplier's page, as a visitor sees it.
  got := public.buyer_supplier_profile('ci-0161-co');
  if got is null then raise exception 'no profile for the published company'; end if;
  if (select array_agg(c ->> 'certificate_no') from jsonb_array_elements(got -> 'certifications') c)
     is distinct from array['CI-0161-HELD'] then
    raise exception 'the profile lists certificates %, expected only the held one', got -> 'certifications';
  end if;
  if position('CI-0161-REJ' in got::text) > 0 then
    raise exception 'a rejected certificate is somewhere in the profile: %', got;
  end if;

  -- The pills, both the company's own and the view that adds inherited ones.
  if (select array_agg(value) from public.v_supplier_registry_ids_direct where supplier_id = co and label like '% Cert #')
     is distinct from array['CI-0161-HELD'] then
    raise exception 'the registry pills carry %, expected only the held certificate',
      (select array_agg(value) from public.v_supplier_registry_ids_direct where supplier_id = co);
  end if;
  if exists (select 1 from public.v_supplier_registry_ids where value like 'CI-0161-REJ%') then
    raise exception 'a rejected certificate is a pill in v_supplier_registry_ids';
  end if;

  -- The buyer who saved the company.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000a161', true);

  got := public.compliance_expiring_certs(90);
  if (select array_agg(r ->> 'certificate_no') from jsonb_array_elements(got -> 'rows') r)
     is distinct from array['CI-0161-HELD'] or (got ->> 'total')::int <> 1 then
    raise exception 'the compliance hub lists %', got;
  end if;

  got := public.compliance_msa_inputs();
  if (select array_agg(c ->> 'kind') from jsonb_array_elements(got -> 'by_certification') c)
     is distinct from array['gots'] or (got ->> 'expiring_certs_90d')::int <> 1 then
    raise exception 'the statement inputs count rejected certificates: % / %',
      got -> 'by_certification', got -> 'expiring_certs_90d';
  end if;

  got := public.buyer_dashboard();
  if (select array_agg(a ->> 'cert_kind') from jsonb_array_elements(got -> 'alerts') a)
     is distinct from array['gots'] then
    raise exception 'the dashboard alerts on %', got -> 'alerts';
  end if;
  if (select array_agg(a ->> 'detail') from jsonb_array_elements(got -> 'recent_activity') a where a ->> 'kind' = 'cert_added')
     is distinct from array['gots'] then
    raise exception 'the dashboard feed announces %', got -> 'recent_activity';
  end if;

  got := public.buyer_smart_match(jsonb_build_object('certs', jsonb_build_array('gots', 'wrap'), 'limit', 100));
  txt := (select string_agg(x, '|' order by x)
            from jsonb_array_elements(got -> 'results') r, jsonb_array_elements_text(r -> 'match_reasons') x
           where r ->> 'slug' = 'ci-0161-co');
  if txt is distinct from 'Certified: GOTS' then
    raise exception 'the match gives the company the reasons %, expected only its GOTS certificate', txt;
  end if;

  reset role;
end
$$;

rollback;
