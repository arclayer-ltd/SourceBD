-- 0161 — Switch on the timers of every source whose reader works (#639).
--
-- THE FAULT
--   Every row in etl_schedules has been `enabled = false` since 6 Oct 2026, so the queue job (which runs
--   on the server every minute and is working) never queues a timed read. Since then only the sources a
--   Firecrawl monitor wakes have been read. Last reads in production, 24 Nov 2026: OFAC 8 Oct, EU 6 Oct,
--   UFLPA 29 Oct, RSC 2 Oct, WRAP and OEKO-TEX 10 Oct, GOTS 14 Oct, EPB 30 Jul.
--
-- WHAT THIS DOES
--   Turns on the timers below and sets each one's first run to the next opening of its own window
--   (`metadata.run_window_utc`, plus its jitter), the same rule the queue uses after every run. A source with
--   no window runs on the next queue tick. So the sanctions lists, ILAB and UFLPA read at 02:xx UTC, RSC at
--   01:xx, the certificate lists at 03:xx and 04:xx, the brand lists at 00:xx and the registers 19:xx-23:xx,
--   all within 25 hours of this being applied (a day, plus at most an hour of jitter).
--
--   A row an admin has already switched on is left exactly as it is. `rsc` and `rsc_reports` were made
--   through /admin/sources, not by a migration, so they are inserted here with production's settings if they
--   are missing (a fresh database), and only switched on if they exist.
--
--   Left off, on purpose:
--     uk_ofsi          its list was retired by the UK: the reader is broken (#660).
--     bkmea_detail     its last run, 31 Jul, spent 590 Firecrawl credits; what it spends depends on how many
--                      BKMEA list rows change, and the last two BKMEA reads were held for review.
--     refresh_monitors, verify_evidence, sbi_recompute
--                      upkeep jobs, not source reads. sbi_recompute already runs after every register read.
--   cbp_wro (#683) and brand_primark (#684) have no timer row.
--
--   Spending: only uflpa, ilab_tvpra, bkmea_web, rsc_reports, sa8000 and three brand lists use the paid
--   crawler, at 1-6 credits a run in their recent runs. The per-run and monthly ceilings in
--   etl/core/acquiring.py still stop any run that would pass them.
--
-- REVERSE
--   update public.etl_schedules set enabled = false, next_run_at = null, updated_at = now()
--    where scraper_code in (<the codes below>);

insert into public.etl_schedules (scraper_code, enabled, interval_minutes, metadata)
values
  ('rsc',         false, 10080, '{"max_age_spec": "etl-freshness S5", "max_age_hours": 336, "run_window_utc": 1, "jitter_minutes": 30}'),
  ('rsc_reports', false, 43200, '{}')
on conflict (scraper_code) do nothing;

update public.etl_schedules s
   set enabled = true,
       next_run_at = case
         when s.metadata ? 'run_window_utc' then
           date_trunc('day', now(), 'UTC')
           + make_interval(hours => (s.metadata ->> 'run_window_utc')::int)
           + case when date_trunc('day', now(), 'UTC')
                       + make_interval(hours => (s.metadata ->> 'run_window_utc')::int) <= now()
                  then interval '1 day' else interval '0' end
           + make_interval(mins => floor(random() * coalesce((s.metadata ->> 'jitter_minutes')::int, 15))::int)
         else now()
       end,
       updated_at = now()
 where s.scraper_code in (
         -- Sanctions and forced-labour lists
         'ofac_sdn', 'eu_sanctions', 'uflpa', 'ilab_tvpra',
         -- Safety register
         'rsc', 'rsc_reports',
         -- Certificate lists
         'wrap', 'gots', 'oeko_tex', 'sa8000',
         -- Registers
         'bgmea_web', 'bkmea_web', 'bgapmea_web', 'epb_web',
         -- Brand supplier lists
         'brand_hm', 'brand_next', 'brand_asos', 'brand_ms')
   and not s.enabled;
