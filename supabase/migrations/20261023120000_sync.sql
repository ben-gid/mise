-- Sync: what a linked phone has written, mirrored per user. The phone's files
-- stay the source of truth; these rows are how a second phone hears about them.
-- Nothing is ever deleted by a client — a delete is a deleted_at marker, so it
-- reaches every phone instead of being resurrected by the next one to sync.
--
-- Linked users only. An anonymous user has nowhere to sync *to*: no other phone
-- can ever sign in as it.

create table public.recipe_versions (
  user_id uuid not null references auth.users on delete cascade,
  id text not null,
  parent_id text,
  recipe jsonb,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table public.cook_entries (
  user_id uuid not null references auth.users on delete cascade,
  version_id text not null,
  id text not null,
  date timestamptz,
  servings int,
  stars int,
  note text,
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, version_id, id)
);

-- The units.meta line as written: "<weight>,<volume>,<measureBy>".
create table public.unit_settings (
  user_id uuid primary key references auth.users on delete cascade,
  value text,
  deleted_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Phones pull "everything since my cursor", so updated_at is the database's
-- clock, never the phone's: a phone set an hour slow would otherwise write
-- rows behind every other phone's cursor. Invoker rights, unlike
-- create_profile: it only touches the row being written.
create function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger touch before insert or update on public.recipe_versions
  for each row execute function public.touch_updated_at();
create trigger touch before insert or update on public.cook_entries
  for each row execute function public.touch_updated_at();
create trigger touch before insert or update on public.unit_settings
  for each row execute function public.touch_updated_at();

create index recipe_versions_cursor on public.recipe_versions (user_id, updated_at);
create index cook_entries_cursor on public.cook_entries (user_id, updated_at);

-- Select, insert and update; no delete policy at all, since rows are only
-- ever tombstoned.
do $$
declare
  t text;
begin
  foreach t in array array['recipe_versions', 'cook_entries', 'unit_settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format($p$
      create policy "linked users read their own rows" on public.%I
        for select to authenticated
        using ((select auth.uid()) = user_id
          and (select (auth.jwt()->>'is_anonymous')::boolean) is false)
    $p$, t);
    execute format($p$
      create policy "linked users add their own rows" on public.%I
        for insert to authenticated
        with check ((select auth.uid()) = user_id
          and (select (auth.jwt()->>'is_anonymous')::boolean) is false)
    $p$, t);
    execute format($p$
      create policy "linked users change their own rows" on public.%I
        for update to authenticated
        using ((select auth.uid()) = user_id
          and (select (auth.jwt()->>'is_anonymous')::boolean) is false)
        with check ((select auth.uid()) = user_id
          and (select (auth.jwt()->>'is_anonymous')::boolean) is false)
    $p$, t);
  end loop;
end;
$$;

-- Photos the cook picked from the phone (`mise://<filename>`), one folder per
-- user. Private: a url to one is only ever made by its owner's own session.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 5242880, array['image/*']);

create policy "linked users read their own photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (select (auth.jwt()->>'is_anonymous')::boolean) is false);

create policy "linked users add their own photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (select (auth.jwt()->>'is_anonymous')::boolean) is false);

create policy "linked users replace their own photos" on storage.objects
  for update to authenticated
  using (bucket_id = 'photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (select (auth.jwt()->>'is_anonymous')::boolean) is false);
