-- 0162 asserted by running it: rfq_get tells the buyer which suppliers have claimed their company
-- (and so can read the RFQ) and which have not; a supplier reading the RFQ sees only itself among the
-- targets; is_claimed follows claimed_by; a signed-in user can read is_claimed but still not
-- claimed_by, and a visitor can read neither.
\set ON_ERROR_STOP on

begin;

-- Unpublished, so no source record is needed: rfq_get reads a target whatever its listing.

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-00000000b162', 'buyer-0162@example.invalid',    '{"role":"buyer"}'::jsonb),
  ('00000000-0000-4000-8000-00000000c162', 'supplier-0162@example.invalid', '{"role":"supplier"}'::jsonb)
on conflict do nothing;

insert into public.suppliers (id, slug, company_name, company_name_norm, city, district, is_published, is_sanctioned, claimed_by) values
  ('00000000-0000-4000-8000-0000000a1162', 'ci-0162-claimed',   'CI 0162 Claimed Ltd',   'ci 0162 claimed ltd',   'Dhaka', 'Dhaka', false, false, '00000000-0000-4000-8000-00000000c162'),
  ('00000000-0000-4000-8000-0000000a2162', 'ci-0162-unclaimed', 'CI 0162 Unclaimed Ltd', 'ci 0162 unclaimed ltd', 'Dhaka', 'Dhaka', false, false, null);

insert into public.rfqs (id, buyer_id, product_title, quantity, quantity_unit, target_supplier_ids)
  values ('00000000-0000-4000-8000-0000000d1162', '00000000-0000-4000-8000-00000000b162', 'CI tee', 1000, 'pcs',
          array['00000000-0000-4000-8000-0000000a1162', '00000000-0000-4000-8000-0000000a2162']::uuid[]);

do $$
declare
  buyer     constant uuid := '00000000-0000-4000-8000-00000000b162';
  supplier  constant uuid := '00000000-0000-4000-8000-00000000c162';
  claimed   constant uuid := '00000000-0000-4000-8000-0000000a1162';
  unclaimed constant uuid := '00000000-0000-4000-8000-0000000a2162';
  rfq       constant uuid := '00000000-0000-4000-8000-0000000d1162';
  doc       jsonb;
begin
  if not has_column_privilege('authenticated', 'public.suppliers', 'is_claimed', 'select') then
    raise exception '0162: a signed-in user cannot read is_claimed';
  end if;
  if has_column_privilege('authenticated', 'public.suppliers', 'claimed_by', 'select') then
    raise exception '0162: a signed-in user can read claimed_by, which names a person';
  end if;
  if has_column_privilege('anon', 'public.suppliers', 'is_claimed', 'select') then
    raise exception '0162: a visitor can read is_claimed';
  end if;

  -- The buyer: both suppliers, each saying whether it can read the RFQ.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', buyer::text, true);
  doc := public.rfq_get(rfq);
  reset role;
  if jsonb_array_length(doc->'targets') <> 2 then
    raise exception '0162: the buyer sees % targets, not 2', jsonb_array_length(doc->'targets');
  end if;
  if (select (t->>'is_claimed')::boolean from jsonb_array_elements(doc->'targets') t where (t->>'id')::uuid = claimed) is distinct from true then
    raise exception '0162: the claimed supplier is not marked claimed: %', doc->'targets';
  end if;
  if (select (t->>'is_claimed')::boolean from jsonb_array_elements(doc->'targets') t where (t->>'id')::uuid = unclaimed) is distinct from false then
    raise exception '0162: the unclaimed supplier is not marked unclaimed: %', doc->'targets';
  end if;

  -- The supplier: the RFQ, with itself as the only target.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', supplier::text, true);
  doc := public.rfq_get(rfq);
  reset role;
  if doc is null then raise exception '0162: the claimed supplier cannot read its RFQ'; end if;
  if jsonb_array_length(doc->'targets') <> 1 or (doc->'targets'->0->>'id')::uuid <> claimed then
    raise exception '0162: a supplier sees the other suppliers asked: %', doc->'targets';
  end if;

  -- The flag follows claimed_by.
  update public.suppliers set claimed_by = null where id = claimed;
  if (select is_claimed from public.suppliers where id = claimed) then
    raise exception '0162: is_claimed stayed true after the claim was removed';
  end if;
end
$$;

rollback;
