-- One row per user, anonymous ones included: what the server needs to know about
-- them beyond who they are. Created by trigger so no client ever writes it, and
-- readable only by its owner. pro_until is set by the RevenueCat webhook and
-- free_tries_used by the LLM routes, both with the secret key, so there is no
-- client write policy at all.
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  pro_until timestamptz,
  free_tries_used int not null default 0,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "users read their own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

-- security definer with an empty search_path: the trigger runs as the auth
-- service, which can't see public on its own, and a mutable search_path is the
-- injection the security advisor flags.
create function public.create_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.create_profile();
