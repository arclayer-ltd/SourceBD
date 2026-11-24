-- 0164 asserted by running it: a claim is approved by its email link alone only when the proof email's
-- domain is specific to that company. An email at the company's own domain is approved by the click; a
-- Gmail address that matches the company's listed Gmail, and a domain two companies share, each wait for
-- a person after the click. A signed-out visitor can call neither function.
\set ON_ERROR_STOP on

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-00000000b164', 'supplier-0164@example.invalid', '{"role":"supplier"}'::jsonb)
on conflict do nothing;

insert into public.suppliers (slug, company_name, company_name_norm, city, district, website, email_primary, is_published, is_sanctioned)
values
  ('ci-0164-own',    'CI 0164 Own Knit Ltd',  'ci 0164 own knit ltd',  'Dhaka', 'Dhaka', 'https://www.ci0164own.example/about', 'info@ci0164own.example', false, false),
  ('ci-0164-gmail',  'CI 0164 Gmail Ltd',     'ci 0164 gmail ltd',     'Dhaka', 'Dhaka', null,                                  'ci0164.knit@gmail.com',   false, false),
  ('ci-0164-group1', 'CI 0164 Group Unit 1',  'ci 0164 group unit 1',  'Dhaka', 'Dhaka', 'http://ci0164group.example',          null,                      false, false),
  ('ci-0164-group2', 'CI 0164 Group Unit 2',  'ci 0164 group unit 2',  'Dhaka', 'Dhaka', null,                                  'sales@ci0164group.example', false, false);

-- Published only once each holds a Tier 1 source (enforce_publish_tier); claim_initiate wants published.
insert into public.source_records (supplier_id, source_id, source_tier, source_ref, fields, fetched_at, status)
select sp.id, s.id, s.tier, 'CI-0164-' || sp.slug, '{"rsc_status_name": "active"}'::jsonb, now(), 'active'::public.evidence_status
  from public.suppliers sp, public.sources s
 where sp.slug like 'ci-0164-%' and s.code = 'RSC';

update public.suppliers set is_published = true where slug like 'ci-0164-%';

do $$
declare
  me   constant uuid := '00000000-0000-4000-8000-00000000b164';
  own  uuid := (select id from public.suppliers where slug = 'ci-0164-own');
  gml  uuid := (select id from public.suppliers where slug = 'ci-0164-gmail');
  grp  uuid := (select id from public.suppliers where slug = 'ci-0164-group1');
  r_own jsonb;
  r_gml jsonb;
  r_grp jsonb;
  v_own jsonb;
  v_gml jsonb;
begin
  if has_function_privilege('anon', 'public.claim_initiate(uuid, text, text)', 'execute')
     or has_function_privilege('anon', 'public.claim_verify_email(text)', 'execute') then
    raise exception '0164: a signed-out visitor can still call claim_initiate or claim_verify_email';
  end if;
  if not has_function_privilege('authenticated', 'public.claim_verify_email(text)', 'execute') then
    raise exception '0164: a signed-in supplier can no longer spend a claim link';
  end if;
  if has_function_privilege('authenticated', 'public._claim_domain_is_specific(uuid, text)', 'execute') then
    raise exception '0164: the domain helper is callable from outside';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', me::text, true);

  r_own := public.claim_initiate(own, 'Mona@CI0164own.example', null);
  r_gml := public.claim_initiate(gml, 'anyone.at.all@gmail.com', null);
  r_grp := public.claim_initiate(grp, 'x@ci0164group.example', null);

  if r_own ->> 'method' <> 'domain_email' then
    raise exception '0164: an email at the company''s own domain is %, expected domain_email', r_own ->> 'method';
  end if;
  if r_gml ->> 'method' <> 'manual_review' then
    raise exception '0164: a Gmail address that matches a listed Gmail is %, expected manual_review', r_gml ->> 'method';
  end if;
  if r_grp ->> 'method' <> 'manual_review' then
    raise exception '0164: a domain two companies share is %, expected manual_review', r_grp ->> 'method';
  end if;

  v_own := public.claim_verify_email(r_own ->> 'verification_token');
  v_gml := public.claim_verify_email(r_gml ->> 'verification_token');

  reset role;

  if v_own ->> 'outcome' <> 'approved' then
    raise exception '0164: the own-domain click gave %, expected approved', v_own;
  end if;
  if v_gml ->> 'outcome' <> 'pending_admin' then
    raise exception '0164: the Gmail click gave %, expected pending_admin', v_gml;
  end if;
  if (select claimed_by from public.suppliers where id = own) is distinct from me then
    raise exception '0164: the own-domain click did not make the claimant the owner';
  end if;
  if (select claimed_by from public.suppliers where id = gml) is not null then
    raise exception '0164: a Gmail click made somebody the owner with no person deciding';
  end if;
  if (select status::text from public.claim_requests where id = (r_gml ->> 'claim_id')::uuid) <> 'email_verified' then
    raise exception '0164: the Gmail claim is not waiting for a person';
  end if;
end
$$;

rollback;
