-- 0159: a new account starts as a buyer or a supplier, and nothing else.
--
-- The profile row created at sign-up took its role from the sign-up data as sent. The form only
-- ever sends "buyer" or "supplier"; the database now holds that itself. Anything other than
-- "supplier" becomes "buyer", including a value that is not a role at all, which used to fail the
-- sign-up with a cast error.
--
-- An admin is made by changing the role on an existing profile, with database access. Sign-up
-- never makes one.
--
-- Safe on a live database: one function replaced, no row touched. Safe to run twice.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, role)
  values (
    new.id,
    case when new.raw_user_meta_data ->> 'role' = 'supplier'
         then 'supplier'::public.user_role
         else 'buyer'::public.user_role
    end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
