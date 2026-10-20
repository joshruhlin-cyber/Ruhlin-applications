-- Step Squad — Supabase schema
-- Paste this whole file into the Supabase SQL editor and run it once.
-- Safe to re-run: functions and policies are replaced, tables are kept.

create extension if not exists pgcrypto;

-- ─────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Walker' check (char_length(display_name) between 1 and 40),
  emoji        text not null default '🚶' check (char_length(emoji) between 1 and 8),
  daily_goal   int  not null default 10000 check (daily_goal between 500 and 100000),
  created_at   timestamptz not null default now()
);

-- Kept apart from profiles so friends can never read your token.
create table if not exists public.ingest_tokens (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  token      text not null unique default encode(gen_random_bytes(18), 'hex'),
  created_at timestamptz not null default now()
);

create table if not exists public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 60),
  invite_code text not null unique,
  created_by  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id  uuid not null references public.groups(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists group_members_user_idx on public.group_members(user_id);

create table if not exists public.daily_steps (
  user_id    uuid not null references auth.users(id) on delete cascade,
  day        date not null,
  steps      int  not null check (steps between 0 and 200000),
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);

-- kind: 'progress' (a sync that added steps), 'milestone' (crossed 5k, 10k, …),
--       'goal' (hit personal daily goal), 'cheer' (user_id cheered target_user)
create table if not exists public.feed_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('progress', 'milestone', 'goal', 'cheer')),
  day         date not null,
  steps       int,
  delta       int,
  target_user uuid references auth.users(id) on delete cascade,
  emoji       text,
  created_at  timestamptz not null default now()
);
create index if not exists feed_events_user_created_idx on public.feed_events(user_id, created_at desc);

-- ─────────────────────────────────────────────────────────────
-- Helpers (security definer so RLS policies can use them without recursion)
-- ─────────────────────────────────────────────────────────────

create or replace function public.is_member(p_group uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from group_members where group_id = p_group and user_id = auth.uid()
  );
$$;

create or replace function public.shares_group(p_other uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_other = auth.uid() or exists (
    select 1
    from group_members mine
    join group_members theirs on theirs.group_id = mine.group_id
    where mine.user_id = auth.uid() and theirs.user_id = p_other
  );
$$;

-- New sign-ups get a profile and a Shortcut token automatically.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name)
  values (new.id, left(coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Walker'), 40))
  on conflict (id) do nothing;
  insert into ingest_tokens (user_id) values (new.id) on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Core step recorder shared by the Shortcut endpoint and manual logging.
-- Writes today's total and emits feed events for meaningful progress.
create or replace function public._record_steps(p_user uuid, p_steps int, p_day date)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_prev  int;
  v_goal  int;
  v_mark  int;
begin
  if p_steps is null or p_steps < 0 or p_steps > 200000 then
    raise exception 'steps must be between 0 and 200000';
  end if;
  if p_day is null or p_day > current_date + 1 or p_day < current_date - 7 then
    raise exception 'day must be within the last week';
  end if;

  select steps into v_prev from daily_steps where user_id = p_user and day = p_day;
  v_prev := coalesce(v_prev, 0);

  insert into daily_steps (user_id, day, steps, updated_at)
  values (p_user, p_day, p_steps, now())
  on conflict (user_id, day) do update set steps = excluded.steps, updated_at = now();

  if p_steps > v_prev then
    -- Skip tiny syncs so the feed stays readable.
    if p_steps - v_prev >= 250 then
      insert into feed_events (user_id, kind, day, steps, delta)
      values (p_user, 'progress', p_day, p_steps, p_steps - v_prev);
    end if;

    select daily_goal into v_goal from profiles where id = p_user;

    for v_mark in select generate_series(5000, 50000, 5000) loop
      -- A milestone that equals the goal is announced as the goal instead.
      if v_prev < v_mark and p_steps >= v_mark and v_mark is distinct from v_goal then
        insert into feed_events (user_id, kind, day, steps, delta)
        values (p_user, 'milestone', p_day, v_mark, null);
      end if;
    end loop;

    if v_goal is not null and v_prev < v_goal and p_steps >= v_goal then
      insert into feed_events (user_id, kind, day, steps, delta)
      values (p_user, 'goal', p_day, v_goal, null);
    end if;
  end if;

  return p_steps;
end;
$$;
revoke all on function public._record_steps(uuid, int, date) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- RPCs called by the app and the Shortcut
-- ─────────────────────────────────────────────────────────────

-- Called by the iOS Shortcut. No login needed — the secret token identifies you.
create or replace function public.submit_steps(p_token text, p_steps numeric, p_day date default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
  v_day  date := coalesce(p_day, current_date);
  v_total int;
begin
  select user_id into v_user from ingest_tokens where token = p_token;
  if v_user is null then
    raise exception 'invalid token';
  end if;
  v_total := public._record_steps(v_user, round(p_steps)::int, v_day);
  return json_build_object('ok', true, 'day', v_day, 'steps', v_total);
end;
$$;
grant execute on function public.submit_steps(text, numeric, date) to anon, authenticated;

create or replace function public.log_my_steps(p_steps int, p_day date)
returns int language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  return public._record_steps(auth.uid(), p_steps, p_day);
end;
$$;
grant execute on function public.log_my_steps(int, date) to authenticated;

create or replace function public.get_my_token()
returns text language sql stable security definer set search_path = public as $$
  select token from ingest_tokens where user_id = auth.uid();
$$;
grant execute on function public.get_my_token() to authenticated;

create or replace function public.rotate_my_token()
returns text language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into ingest_tokens (user_id) values (auth.uid())
  on conflict (user_id) do update set token = encode(gen_random_bytes(18), 'hex'), created_at = now()
  returning token into v_token;
  return v_token;
end;
$$;
grant execute on function public.rotate_my_token() to authenticated;

create or replace function public.create_group(p_name text)
returns public.groups language plpgsql security definer set search_path = public as $$
declare
  v_group groups;
  v_code  text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  loop
    -- 6 chars, no look-alikes (0/O, 1/I/L)
    select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
      into v_code from generate_series(1, 6);
    exit when not exists (select 1 from groups where invite_code = v_code);
  end loop;
  insert into groups (name, invite_code, created_by)
  values (trim(p_name), v_code, auth.uid())
  returning * into v_group;
  insert into group_members (group_id, user_id) values (v_group.id, auth.uid());
  return v_group;
end;
$$;
grant execute on function public.create_group(text) to authenticated;

create or replace function public.join_group(p_code text)
returns public.groups language plpgsql security definer set search_path = public as $$
declare v_group groups;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into v_group from groups where invite_code = upper(trim(p_code));
  if v_group.id is null then raise exception 'no group with that invite code'; end if;
  insert into group_members (group_id, user_id) values (v_group.id, auth.uid())
  on conflict do nothing;
  return v_group;
end;
$$;
grant execute on function public.join_group(text) to authenticated;

create or replace function public.leave_group(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from group_members where group_id = p_group and user_id = auth.uid();
  -- Last one out turns off the lights.
  delete from groups g where g.id = p_group
    and not exists (select 1 from group_members m where m.group_id = g.id);
end;
$$;
grant execute on function public.leave_group(uuid) to authenticated;

create or replace function public.send_cheer(p_target uuid, p_emoji text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_target = auth.uid() then raise exception 'cheer someone else!'; end if;
  if not public.shares_group(p_target) then raise exception 'not in a group together'; end if;
  if p_emoji is null or char_length(p_emoji) > 8 then raise exception 'bad emoji'; end if;
  -- One cheer per person per target every 2 minutes.
  if exists (
    select 1 from feed_events
    where kind = 'cheer' and user_id = auth.uid() and target_user = p_target
      and created_at > now() - interval '2 minutes'
  ) then
    raise exception 'easy there — you just cheered them';
  end if;
  insert into feed_events (user_id, kind, day, target_user, emoji)
  values (auth.uid(), 'cheer', current_date, p_target, p_emoji);
end;
$$;
grant execute on function public.send_cheer(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Row level security — you only see people you share a group with
-- ─────────────────────────────────────────────────────────────

alter table public.profiles      enable row level security;
alter table public.ingest_tokens enable row level security;
alter table public.groups        enable row level security;
alter table public.group_members enable row level security;
alter table public.daily_steps   enable row level security;
alter table public.feed_events   enable row level security;

drop policy if exists "profiles: read squad" on public.profiles;
create policy "profiles: read squad" on public.profiles
  for select to authenticated using (public.shares_group(id));

drop policy if exists "profiles: update self" on public.profiles;
create policy "profiles: update self" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ingest_tokens: no policies → only reachable through get_my_token / rotate_my_token.

drop policy if exists "groups: read own" on public.groups;
create policy "groups: read own" on public.groups
  for select to authenticated using (public.is_member(id));

drop policy if exists "groups: rename own" on public.groups;
create policy "groups: rename own" on public.groups
  for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());

drop policy if exists "members: read own groups" on public.group_members;
create policy "members: read own groups" on public.group_members
  for select to authenticated using (public.is_member(group_id));

drop policy if exists "steps: read squad" on public.daily_steps;
create policy "steps: read squad" on public.daily_steps
  for select to authenticated using (public.shares_group(user_id));

drop policy if exists "feed: read squad" on public.feed_events;
create policy "feed: read squad" on public.feed_events
  for select to authenticated using (public.shares_group(user_id));

grant select on public.profiles, public.groups, public.group_members,
                public.daily_steps, public.feed_events to authenticated;
grant update (display_name, emoji, daily_goal) on public.profiles to authenticated;
grant update (name) on public.groups to authenticated;
revoke all on public.ingest_tokens from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Realtime — live feed and leaderboard updates
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and tablename = 'feed_events') then
      alter publication supabase_realtime add table public.feed_events;
    end if;
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and tablename = 'daily_steps') then
      alter publication supabase_realtime add table public.daily_steps;
    end if;
  end if;
end $$;
