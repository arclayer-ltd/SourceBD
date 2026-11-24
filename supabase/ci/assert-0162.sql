-- 0162 asserted: the UK sanctions source is named for the UK Sanctions List and links to its page, and
-- applying it again changes nothing.
\set ON_ERROR_STOP on

begin;

do $$
begin
  if (select (display_name, base_url) from public.sources where code = 'UK_OFSI')
     is distinct from ('UK Sanctions List'::text, 'https://www.gov.uk/government/publications/the-uk-sanctions-list'::text) then
    raise exception '0162: UK_OFSI still reads %',
      (select display_name || ' ' || base_url from public.sources where code = 'UK_OFSI');
  end if;
end
$$;

\ir ../migrations/0162_uk_sanctions_list_source.sql

do $$
begin
  if (select count(*) from public.sources where code = 'UK_OFSI' and display_name = 'UK Sanctions List') <> 1 then
    raise exception '0162: re-applied, UK_OFSI is not one row named for the UK Sanctions List';
  end if;
end
$$;

rollback;
