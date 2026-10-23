-- create_profile only ever runs from its trigger. Postgres grants EXECUTE to
-- public by default, which put it on /rest/v1/rpc for anyone holding the
-- publishable key; the trigger doesn't need the grant to fire.
revoke execute on function public.create_profile() from public, anon, authenticated;
