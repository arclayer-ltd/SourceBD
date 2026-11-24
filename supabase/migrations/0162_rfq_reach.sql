-- 0162: an RFQ says which of its suppliers can read it.
--
-- An RFQ reaches a supplier only once someone has claimed that company: rfq_list and rfq_get show it
-- to the user in suppliers.claimed_by, and to nobody else on the supplier side. The composer and the
-- RFQ page could not tell the buyer this, because claimed_by is closed to signed-in users (it names a
-- person). So:
--
--   * suppliers.is_claimed: true when the company has been claimed. Derived from claimed_by, so it
--     cannot drift from it, and it names nobody. Readable by signed-in users, as is_sanctioned is.
--   * rfq_get: each target carries is_claimed, so the RFQ page can say which suppliers it reached.
--   * rfq_get: a supplier reading an RFQ sees itself as the only target. Before this every supplier
--     saw every other supplier the buyer asked, while the composer promises "No supplier sees who else
--     you asked".
--
-- rfq_get is 0106's body with those two changes. Safe on a live database: one derived column (the
-- table is rewritten once to fill it; no value is changed) and one function replaced. Safe to run
-- twice. assert-0162.sql holds it.

alter table public.suppliers
  add column if not exists is_claimed boolean generated always as (claimed_by is not null) stored;

grant select (is_claimed) on public.suppliers to authenticated;

-- rfq_get — 0106's body, plus each target's is_claimed, and a supplier sees only itself among the
-- targets.
create or replace function public.rfq_get(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_rfq          record;
  v_is_buyer     boolean := false;
  v_is_supplier  boolean := false;
  v_my_supplier  uuid;
  v_targets      jsonb;
  v_quotes       jsonb;
  v_thread_id    uuid;
begin
  if v_uid is null then
    return null;
  end if;
  if p_id is null then
    return null;
  end if;

  select r.* into v_rfq from public.rfqs r where r.id = p_id;
  if not found then
    return null;
  end if;

  v_is_buyer := (v_rfq.buyer_id = v_uid);

  select s.id into v_my_supplier
    from public.suppliers s
   where s.claimed_by = v_uid
     and s.id = any (v_rfq.target_supplier_ids)
   limit 1;
  v_is_supplier := v_my_supplier is not null;

  if not (v_is_buyer or v_is_supplier) then
    return null;
  end if;

  -- Targeted suppliers — buyer-safe shape (no PII). The buyer sees every one and whether it has
  -- claimed its company (only a claimed supplier can read the RFQ); a supplier sees only itself.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',           s.id,
        'slug',         s.slug,
        'company_name', s.company_name,
        'entity_type',  s.entity_type::text,
        'city',         s.city,
        'district',     s.district,
        'is_claimed',   s.claimed_by is not null
      )
      order by s.company_name
    ),
    '[]'::jsonb
  )
  into v_targets
  from public.suppliers s
  where s.id = any (v_rfq.target_supplier_ids)
    and (v_is_buyer or s.id = v_my_supplier);

  -- Quotes — buyer sees all; supplier sees only own.
  with q as (
    select
      rq.id, rq.rfq_id, rq.supplier_id, rq.unit_price, rq.currency,
      rq.lead_time_days, rq.moq, rq.valid_until, rq.notes,
      rq.status::text as status, rq.created_at, rq.updated_at,
      s.slug         as supplier_slug,
      s.company_name as supplier_name,
      s.entity_type::text as supplier_entity_type
    from public.rfq_quotes rq
    join public.suppliers s on s.id = rq.supplier_id
    where rq.rfq_id = p_id
      and (v_is_buyer or rq.supplier_id = v_my_supplier)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',                  id,
        'supplier_id',         supplier_id,
        'supplier_slug',       supplier_slug,
        'supplier_name',       supplier_name,
        'supplier_entity_type', supplier_entity_type,
        'unit_price',          unit_price,
        'currency',            currency,
        'lead_time_days',      lead_time_days,
        'moq',                 moq,
        'valid_until',         valid_until,
        'notes',               notes,
        'status',              status,
        'created_at',          created_at,
        'updated_at',          updated_at
      )
      order by created_at asc
    ),
    '[]'::jsonb
  )
  into v_quotes
  from q;

  -- Optional thread_id for the caller's perspective (for "Open thread" UX).
  if v_is_buyer then
    select id into v_thread_id
      from public.message_threads
     where buyer_id = v_uid
       and rfq_id   = p_id
     order by created_at asc
     limit 1;
  elsif v_is_supplier then
    select mt.id into v_thread_id
      from public.message_threads mt
      join public.thread_participants tp
        on tp.thread_id = mt.id and tp.user_id = v_uid
     where mt.rfq_id      = p_id
       and mt.supplier_id = v_my_supplier
     limit 1;
  end if;

  return jsonb_build_object(
    'id',                    v_rfq.id,
    'product_title',         v_rfq.product_title,
    'product_description',   v_rfq.product_description,
    'quantity',              v_rfq.quantity,
    'quantity_unit',         v_rfq.quantity_unit,
    'target_unit_price',     v_rfq.target_unit_price,
    'currency',              v_rfq.currency,
    'ship_to_country',       v_rfq.ship_to_country,
    'ship_by',               v_rfq.ship_by,
    'status',                v_rfq.status::text,
    'accepted_quote_id',     v_rfq.accepted_quote_id,
    'message',               v_rfq.message,
    'questions',             v_rfq.questions,
    'product_id',            v_rfq.product_id,
    'created_at',            v_rfq.created_at,
    'updated_at',            v_rfq.updated_at,
    'viewer_role',           case
                               when v_is_buyer and v_is_supplier then 'both'
                               when v_is_buyer                   then 'buyer'
                               else                                  'supplier'
                             end,
    'targets',               v_targets,
    'quotes',                v_quotes,
    'thread_id',             v_thread_id
  );
end;
$$;


revoke all  on function public.rfq_get(uuid) from public;
grant execute on function public.rfq_get(uuid) to authenticated;

notify pgrst, 'reload schema';
