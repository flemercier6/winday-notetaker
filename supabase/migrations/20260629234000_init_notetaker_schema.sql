-- Winday Notetaker schema: meetings, per-user settings, audio storage, RLS.
-- This mirrors what is deployed on the "Winday Notetaker" Supabase project.

-- updated_at helper (hardened: fixed search_path)
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Meetings: one row per recorded call, carries transcript + summary as it
-- moves through the pipeline. Owned by the authenticated user.
create table if not exists public.meetings (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  title         text not null default 'Untitled meeting',
  status        text not null default 'recorded',
  audio_path    text,
  transcript    jsonb,
  summary       jsonb,
  language      text,
  notion_page_url text,
  error_message text,
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.meetings enable row level security;

create policy "meetings_select_own" on public.meetings
  for select using (auth.uid() = user_id);
create policy "meetings_insert_own" on public.meetings
  for insert with check (auth.uid() = user_id);
create policy "meetings_update_own" on public.meetings
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "meetings_delete_own" on public.meetings
  for delete using (auth.uid() = user_id);

create trigger meetings_set_updated_at
  before update on public.meetings
  for each row execute function public.set_updated_at();

create index meetings_user_started_idx on public.meetings (user_id, started_at desc);

-- Per-user, NON-secret configuration (model choices, Notion target db, etc.).
-- Secret API keys are NOT stored here — they live in Edge Function secrets.
create table if not exists public.user_settings (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  notion_database_id text,
  auto_export_notion boolean not null default false,
  deepgram_model     text not null default 'nova-3',
  gemini_model       text not null default 'gemini-flash-latest',
  updated_at         timestamptz not null default now()
);

alter table public.user_settings enable row level security;

create policy "user_settings_all_own" on public.user_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create trigger user_settings_set_updated_at
  before update on public.user_settings
  for each row execute function public.set_updated_at();

-- Private bucket for audio recordings. Files are stored under <user_id>/...
insert into storage.buckets (id, name, public)
values ('recordings', 'recordings', false)
on conflict (id) do nothing;

create policy "recordings_select_own" on storage.objects
  for select using (bucket_id = 'recordings' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "recordings_insert_own" on storage.objects
  for insert with check (bucket_id = 'recordings' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "recordings_update_own" on storage.objects
  for update using (bucket_id = 'recordings' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "recordings_delete_own" on storage.objects
  for delete using (bucket_id = 'recordings' and (storage.foldername(name))[1] = auth.uid()::text);
