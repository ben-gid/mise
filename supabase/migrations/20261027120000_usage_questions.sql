-- The question rounds before a recipe reach the model too, so they are rows in
-- usage like any other call. Widening the check is additive: every row the old
-- server wrote still passes it.
alter table public.usage drop constraint usage_kind_check;
alter table public.usage add constraint usage_kind_check
  check (kind in ('write', 'adapt', 'url', 'photo', 'questions'));
