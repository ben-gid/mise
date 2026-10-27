-- One row per /recipe call that reached the model, passed or not: what it
-- cost, so a monthly cap and the price of Pro can be set from real numbers.
-- Written by the server with the secret key and readable only by its owner,
-- like profiles, so there is no client write policy at all.
create table public.usage (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  kind text not null check (kind in ('write', 'adapt', 'url', 'photo')),
  input_tokens int not null,
  output_tokens int not null,
  cost_usd numeric(10, 6) not null,
  ok boolean not null,
  created_at timestamptz not null default now()
);

create index usage_user_month on public.usage (user_id, created_at);

alter table public.usage enable row level security;

create policy "users read their own usage"
  on public.usage for select
  to authenticated
  using ((select auth.uid()) = user_id);
