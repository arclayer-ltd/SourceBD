-- 0164 — A claim is approved without a person only when its proof email is specific to that company (#643).
--
-- THE FAULT
--   claim_initiate (0032) marked a claim `domain_email`, which the link's click approves with nobody
--   looking, whenever the proof email's domain equalled the company's website host or the domain of its
--   listed email. On the live database (24 Nov 2026) 2,101 suppliers list a gmail.com address, 654 a
--   yahoo.com one, and 839 domains are shared by more than one company (Bangladeshi ISPs such as
--   dhaka.net, group domains covering dozens of factories). Anyone with a Gmail account could have taken
--   any of those 2,101 companies by clicking a link. It never happened only because the link itself was
--   broken (the other half of #643).
--
-- WHAT THIS DOES
--   1. _claim_domain_is_specific(supplier, domain): true only when the domain is not a public mailbox
--      provider and no OTHER supplier uses it, as its website host or its listed email's domain.
--   2. claim_initiate: `domain_email` needs the proof email's domain to be the company's website host
--      AND specific to it. A match on the listed email's domain alone no longer counts: a listed address
--      at a mailbox or internet provider (btinternet.com, dhakalink.net, a mistyped gamail.com) is
--      often used by only one supplier, so "used by nobody else" says nothing about who owns it, and no
--      list of providers can be complete. Everything else is `manual_review`: the click confirms the
--      email, a person decides.
--      The body is otherwise the one the live database holds (checked 24 Nov 2026; it equals 0032's).
--   3. Signed-out visitors may no longer call claim_initiate or claim_verify_email. The email link's page
--      now spends the token with the visitor's own session, and the middleware signs them in first.
--
-- The three open claims in production are all `manual_review` already; no row needs changing.
-- Safe on a live database: functions and permissions only. Safe to run twice.
--
-- REVERSE
--   Re-run 0032's claim_initiate; drop function public._claim_domain_is_specific(uuid, text);
--   grant execute on function public.claim_initiate(uuid, text, text), public.claim_verify_email(text) to anon;

create or replace function public._claim_domain_is_specific(p_supplier_id uuid, p_domain text)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(p_domain, '') <> ''
     and p_domain <> all (array[
       'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.uk', 'yahoo.co.in', 'ymail.com', 'rocketmail.com',
       'hotmail.com', 'hotmail.co.uk', 'outlook.com', 'live.com', 'msn.com', 'aol.com', 'icloud.com', 'me.com',
       'mac.com', 'mail.com', 'gmx.com', 'gmx.net', 'yandex.com', 'proton.me', 'protonmail.com', 'zoho.com',
       'rediffmail.com', 'qq.com', '163.com', '126.com'
     ])
     and not exists (
       select 1
         from public.suppliers s
        where s.id <> p_supplier_id
          and (public._claim_email_domain(s.email_primary) = p_domain
               or public._claim_host_root(public._claim_host_from_url(s.website)) = p_domain)
     )
$$;

comment on function public._claim_domain_is_specific(uuid, text) is
  '0164 — true when an email domain can prove one company: not a public mailbox and used by no other supplier.';

revoke all on function public._claim_domain_is_specific(uuid, text) from public, anon, authenticated;

create or replace function public.claim_initiate(
  p_supplier_id   uuid,
  p_proof_email   text,
  p_note          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid           uuid := auth.uid();
  v_role          text;
  v_email         text;
  v_email_domain  text;
  v_supplier      record;
  v_supplier_host text;
  v_method        public.claim_method;
  v_token_raw     text;
  v_token_hash    text;
  v_claim_id      uuid;
  v_now           timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select role::text into v_role from public.profiles where id = v_uid;
  if v_role is null or v_role not in ('supplier', 'admin') then
    raise exception 'caller is not a supplier' using errcode = '42501';
  end if;

  if p_supplier_id is null then
    raise exception 'supplier_id is required' using errcode = '22023';
  end if;

  v_email := lower(btrim(coalesce(p_proof_email, '')));
  if v_email = '' or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'proof_email must be a valid email' using errcode = '22023';
  end if;
  v_email_domain := public._claim_email_domain(v_email);

  if p_note is not null and length(p_note) > 2000 then
    raise exception 'note must be 2000 characters or fewer' using errcode = '22023';
  end if;

  select id, company_name, website, email_primary, is_published, is_sanctioned, claimed_by
    into v_supplier
    from public.suppliers
   where id = p_supplier_id;
  if not found then
    raise exception 'supplier not found' using errcode = 'P0002';
  end if;
  if v_supplier.is_sanctioned then
    raise exception 'supplier is sanctioned and cannot be claimed' using errcode = '42501';
  end if;
  if not v_supplier.is_published then
    raise exception 'supplier is not published' using errcode = '42501';
  end if;
  if v_supplier.claimed_by is not null then
    raise exception 'supplier is already claimed' using errcode = '42501';
  end if;

  -- Rate limit: one initiate per (claimant, supplier) per hour.
  if exists (
    select 1 from public.claim_requests
     where claimant_user_id = v_uid
       and supplier_id      = p_supplier_id
       and created_at       > v_now - interval '1 hour'
  ) then
    raise exception 'a claim was initiated for this supplier within the last hour; please wait'
      using errcode = '53400';
  end if;

  -- domain_email (approved by the click alone) only when the proof email's domain is the company's
  -- website host AND that domain proves this one company (0164). The listed email's domain is not
  -- enough on its own: it may be a provider's, and a stranger can open a mailbox there.
  v_supplier_host := public._claim_host_root(public._claim_host_from_url(v_supplier.website));

  if v_email_domain = v_supplier_host
     and public._claim_domain_is_specific(v_supplier.id, v_email_domain) then
    v_method := 'domain_email';
  else
    v_method := 'manual_review';
  end if;

  -- Generate 32-byte url-safe token (hex). Store only sha256(token).
  v_token_raw  := encode(extensions.gen_random_bytes(32), 'hex');
  v_token_hash := encode(extensions.digest(v_token_raw, 'sha256'), 'hex');

  insert into public.claim_requests (
    supplier_id,
    claimant_user_id,
    proof_email,
    proof_email_domain,
    method,
    status,
    verification_token_hash,
    token_expires_at,
    note
  ) values (
    p_supplier_id,
    v_uid,
    v_email,
    v_email_domain,
    v_method,
    'pending_email',
    v_token_hash,
    v_now + interval '24 hours',
    nullif(btrim(coalesce(p_note, '')), '')
  )
  returning id into v_claim_id;

  return jsonb_build_object(
    'claim_id',           v_claim_id,
    'method',             v_method::text,
    'verification_token', v_token_raw,
    'expires_at',         v_now + interval '24 hours',
    'proof_email',        v_email,
    'supplier', jsonb_build_object(
      'id',           v_supplier.id,
      'company_name', v_supplier.company_name
    )
  );
end;
$$;

revoke all     on function public.claim_initiate(uuid, text, text) from public, anon;
grant  execute on function public.claim_initiate(uuid, text, text) to authenticated;
revoke all     on function public.claim_verify_email(text) from public, anon;
grant  execute on function public.claim_verify_email(text) to authenticated;

notify pgrst, 'reload schema';
