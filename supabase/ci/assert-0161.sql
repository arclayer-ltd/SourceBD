-- 0161 asserted: the timers of the sources with a working reader are on, each due at the next opening of its
-- own window (within 25 hours: a day, plus at most an hour of jitter), and the queue's own due-query picks
-- them up once that time comes. The ones left off stay off. Run again, the migration leaves alone a timer an
-- admin has already set.
\set ON_ERROR_STOP on

begin;

do $$
declare
  on_codes  text[] := array['ofac_sdn', 'eu_sanctions', 'uflpa', 'ilab_tvpra', 'rsc', 'rsc_reports',
                            'wrap', 'gots', 'oeko_tex', 'sa8000', 'bgmea_web', 'bkmea_web', 'bgapmea_web',
                            'epb_web', 'brand_hm', 'brand_next', 'brand_asos', 'brand_ms'];
  off_codes text[] := array['uk_ofsi', 'bkmea_detail', 'sbi_recompute'];
  r record;
  n int;
begin
  select count(*) into n from public.etl_schedules where scraper_code = any (on_codes) and enabled;
  if n <> array_length(on_codes, 1) then
    raise exception '0161: % of % source timers are on: %', n, array_length(on_codes, 1),
      (select string_agg(scraper_code, ', ') from unnest(on_codes) c(scraper_code)
        where not exists (select 1 from public.etl_schedules s where s.scraper_code = c.scraper_code and s.enabled));
  end if;

  for r in select * from public.etl_schedules where scraper_code = any (on_codes) loop
    if r.next_run_at is null then
      raise exception '0161: % is on but has no next run, so the queue never picks it up', r.scraper_code;
    end if;
    if r.metadata ? 'run_window_utc' then
      if r.next_run_at <= now() or r.next_run_at > now() + interval '25 hours' then
        raise exception '0161: % first runs at %, not within the next 25 hours', r.scraper_code, r.next_run_at;
      end if;
      if extract(hour from r.next_run_at at time zone 'UTC') <> (r.metadata ->> 'run_window_utc')::int then
        raise exception '0161: % first runs at %, outside its % UTC window',
          r.scraper_code, r.next_run_at, r.metadata ->> 'run_window_utc';
      end if;
    elsif r.next_run_at > now() then
      raise exception '0161: % has no window but is not due now: %', r.scraper_code, r.next_run_at;
    end if;
  end loop;

  if exists (select 1 from public.etl_schedules where scraper_code = any (off_codes) and enabled) then
    raise exception '0161: a timer meant to stay off is on: %',
      (select string_agg(scraper_code, ', ') from public.etl_schedules where scraper_code = any (off_codes) and enabled);
  end if;

  -- The queue's due-query (etl/jobs/scraper_queue.py, enqueue_due_schedules), 25 hours on: every one is due.
  select count(*) into n from public.etl_schedules
   where enabled = true and next_run_at is not null and next_run_at <= now() + interval '25 hours'
     and scraper_code = any (on_codes);
  if n <> array_length(on_codes, 1) then
    raise exception '0161: only % of % timers would be queued within 25 hours', n, array_length(on_codes, 1);
  end if;
end
$$;

-- Applied to a live database where an admin has already set one timer and another is still off.
update public.etl_schedules set next_run_at = '2030-01-01T00:00:00Z', interval_minutes = 2880 where scraper_code = 'ofac_sdn';
update public.etl_schedules set enabled = false, next_run_at = null where scraper_code = 'gots';

\ir ../migrations/0161_source_timers_on.sql

do $$
begin
  if (select (enabled, next_run_at, interval_minutes) from public.etl_schedules where scraper_code = 'ofac_sdn')
     is distinct from (true, '2030-01-01T00:00:00Z'::timestamptz, 2880) then
    raise exception '0161: re-applied, it overwrote a timer an admin had set';
  end if;
  if not (select enabled and next_run_at is not null from public.etl_schedules where scraper_code = 'gots') then
    raise exception '0161: re-applied, it did not switch on a timer that was off';
  end if;
  if (select count(*) from public.etl_schedules where scraper_code in ('rsc', 'rsc_reports')) <> 2 then
    raise exception '0161: re-applied, rsc and rsc_reports are not one row each';
  end if;
end
$$;

rollback;
