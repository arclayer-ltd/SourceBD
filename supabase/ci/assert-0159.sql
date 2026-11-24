-- 0159 asserted by running it: whatever role the sign-up data asks for, a new account's profile is a
-- buyer or a supplier. Asking for admin gives a buyer; asking for something that is not a role gives a
-- buyer instead of failing the sign-up; no admin is created by any of them.
\set ON_ERROR_STOP on

begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-00000000a159', 'asks-admin-0159@example.invalid',    '{"role":"admin"}'::jsonb),
  ('00000000-0000-4000-8000-00000000b159', 'asks-supplier-0159@example.invalid', '{"role":"supplier"}'::jsonb),
  ('00000000-0000-4000-8000-00000000c159', 'asks-buyer-0159@example.invalid',    '{"role":"buyer"}'::jsonb),
  ('00000000-0000-4000-8000-00000000d159', 'asks-nothing-0159@example.invalid',  '{}'::jsonb),
  ('00000000-0000-4000-8000-00000000e159', 'asks-junk-0159@example.invalid',     '{"role":"owner"}'::jsonb);

do $$
declare
  got text;
begin
  select string_agg(right(id::text, 4) || '=' || role::text, ' ' order by id) into got
    from public.profiles
   where id::text like '00000000-0000-4000-8000-00000000_159';
  if got is distinct from 'a159=buyer b159=supplier c159=buyer d159=buyer e159=buyer' then
    raise exception '0159: sign-up roles are wrong: %', got;
  end if;
end $$;

rollback;
