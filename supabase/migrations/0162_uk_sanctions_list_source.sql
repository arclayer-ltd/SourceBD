-- 0162 — The UK sanctions source names the list it now reads (#660).
--
-- THE FAULT
--   The UK retired OFSI's Consolidated List of Asset Freeze Targets in January 2026 and publishes one list,
--   the UK Sanctions List, kept by the Foreign, Commonwealth and Development Office. The reader
--   (etl/scrapers/uk_ofsi.py) now takes that list; the source row still named the retired one and linked
--   to its page.
--
-- WHAT THIS DOES
--   Renames the UK_OFSI source and points it at the UK Sanctions List's page. The code stays UK_OFSI: it is
--   the key of every stored entry, screening match and timer.
--
-- REVERSE
--   update public.sources
--      set display_name = 'UK OFSI Consolidated Sanctions',
--          base_url = 'https://www.gov.uk/government/publications/financial-sanctions-consolidated-list-of-targets'
--    where code = 'UK_OFSI';

update public.sources
   set display_name = 'UK Sanctions List',
       base_url = 'https://www.gov.uk/government/publications/the-uk-sanctions-list'
 where code = 'UK_OFSI';
