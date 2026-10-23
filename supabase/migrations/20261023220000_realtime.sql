-- Live sync: a phone subscribes to its own rows changing and answers each
-- change with an ordinary sync run. Realtime checks the select policies in
-- 20261023120000_sync.sql before delivering a change, so a phone only ever
-- hears about its own account's rows, and an anonymous user hears nothing.
alter publication supabase_realtime
  add table public.recipe_versions, public.cook_entries, public.unit_settings;
