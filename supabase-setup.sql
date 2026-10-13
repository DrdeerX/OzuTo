-- Ozu Tourism Club App — database setup
-- Run this once in Supabase Dashboard > SQL Editor, on the club's own project.
--
-- Before running: Authentication > Sign In / Providers > Email
--   * keep Email provider enabled
--   * turn OFF "Confirm email" (the app uses username-based addresses that cannot receive mail)
--
-- After running and after you sign up in the app, make yourself the first admin:
--   update public.profiles set role = 'admin' where username = 'your-username';

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Profiles and roles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text,
  role text not null default 'pending' check (role in ('pending','member','admin')),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uname text := lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)));
begin
  insert into public.profiles (id, username, display_name)
  values (new.id, uname, coalesce(new.raw_user_meta_data->>'username', uname));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('member','admin'));
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- Only admins change roles, nobody changes their own role, usernames are fixed.
-- Calls without a signed-in user (SQL editor) are allowed, so the first admin can be set.
create or replace function public.protect_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if new.username is distinct from old.username then
    raise exception 'Username cannot be changed';
  end if;
  if new.role is distinct from old.role then
    if not public.is_admin() then raise exception 'Only admins can change roles'; end if;
    if old.id = auth.uid() then raise exception 'You cannot change your own role'; end if;
  end if;
  return new;
end $$;

drop trigger if exists protect_profile on public.profiles;
create trigger protect_profile before update on public.profiles
  for each row execute function public.protect_profile();

-- ---------------------------------------------------------------------------
-- Schedule
-- ---------------------------------------------------------------------------
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  location text,
  color text,
  all_day boolean not null default false,
  start_at timestamptz not null,
  end_at timestamptz not null,
  rrule jsonb,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.event_exceptions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  original_date date not null,
  cancelled boolean not null default false,
  title text,
  description text,
  location text,
  start_at timestamptz,
  end_at timestamptz,
  unique (event_id, original_date)
);

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  due_date date,
  priority text not null default 'medium' check (priority in ('low','medium','high')),
  status text not null default 'todo' check (status in ('todo','in_progress','done')),
  slots int not null default 1 check (slots between 1 and 50),
  event_id uuid references public.events(id) on delete set null,
  event_date date,
  position double precision not null default 0,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.task_claims (
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  claimed_at timestamptz not null default now(),
  primary key (task_id, user_id)
);

create table if not exists public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null default auth.uid(),
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists task_comments_task_idx on public.task_comments(task_id);

-- Stop over-claiming, also when two people click at the same moment.
create or replace function public.check_claim_slots()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  max_slots int;
  taken int;
begin
  select slots into max_slots from public.tasks where id = new.task_id for update;
  select count(*) into taken from public.task_claims where task_id = new.task_id;
  if taken >= max_slots then raise exception 'TASK_FULL'; end if;
  return new;
end $$;

drop trigger if exists check_claim_slots on public.task_claims;
create trigger check_claim_slots before insert on public.task_claims
  for each row execute function public.check_claim_slots();

-- Claimers (not creator/admin) may only change status and position.
create or replace function public.protect_task()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or old.created_by = auth.uid() or public.is_admin() then return new; end if;
  if (new.title, new.description, new.due_date, new.priority, new.slots, new.event_id, new.event_date, new.created_by)
     is distinct from
     (old.title, old.description, old.due_date, old.priority, old.slots, old.event_id, old.event_date, old.created_by) then
    raise exception 'Only the creator or an admin can edit this task';
  end if;
  return new;
end $$;

drop trigger if exists protect_task on public.tasks;
create trigger protect_task before update on public.tasks
  for each row execute function public.protect_task();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.event_exceptions enable row level security;
alter table public.tasks enable row level security;
alter table public.task_claims enable row level security;
alter table public.task_comments enable row level security;

-- profiles
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select
  using (id = auth.uid() or public.is_member());
drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles for update
  using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles delete" on public.profiles;
create policy "profiles delete" on public.profiles for delete
  using (public.is_admin() and id <> auth.uid());

-- events
drop policy if exists "events read" on public.events;
create policy "events read" on public.events for select using (public.is_member());
drop policy if exists "events insert" on public.events;
create policy "events insert" on public.events for insert
  with check (public.is_member() and created_by = auth.uid());
drop policy if exists "events update" on public.events;
create policy "events update" on public.events for update
  using (created_by = auth.uid() or public.is_admin());
drop policy if exists "events delete" on public.events;
create policy "events delete" on public.events for delete
  using (created_by = auth.uid() or public.is_admin());

-- event_exceptions (allowed for whoever may edit the parent event)
drop policy if exists "exceptions read" on public.event_exceptions;
create policy "exceptions read" on public.event_exceptions for select using (public.is_member());
drop policy if exists "exceptions write" on public.event_exceptions;
create policy "exceptions write" on public.event_exceptions for all
  using (exists (select 1 from public.events e where e.id = event_id and (e.created_by = auth.uid() or public.is_admin())))
  with check (exists (select 1 from public.events e where e.id = event_id and (e.created_by = auth.uid() or public.is_admin())));

-- tasks
drop policy if exists "tasks read" on public.tasks;
create policy "tasks read" on public.tasks for select using (public.is_member());
drop policy if exists "tasks insert" on public.tasks;
create policy "tasks insert" on public.tasks for insert
  with check (public.is_member() and created_by = auth.uid());
drop policy if exists "tasks update" on public.tasks;
create policy "tasks update" on public.tasks for update
  using (public.is_member() and (created_by = auth.uid() or public.is_admin()
         or exists (select 1 from public.task_claims c where c.task_id = id and c.user_id = auth.uid())));
drop policy if exists "tasks delete" on public.tasks;
create policy "tasks delete" on public.tasks for delete
  using (created_by = auth.uid() or public.is_admin());

-- task_claims
drop policy if exists "claims read" on public.task_claims;
create policy "claims read" on public.task_claims for select using (public.is_member());
drop policy if exists "claims insert" on public.task_claims;
create policy "claims insert" on public.task_claims for insert
  with check (public.is_member() and user_id = auth.uid());
drop policy if exists "claims delete" on public.task_claims;
create policy "claims delete" on public.task_claims for delete
  using (user_id = auth.uid() or public.is_admin());

-- task_comments
drop policy if exists "comments read" on public.task_comments;
create policy "comments read" on public.task_comments for select using (public.is_member());
drop policy if exists "comments insert" on public.task_comments;
create policy "comments insert" on public.task_comments for insert
  with check (public.is_member() and user_id = auth.uid());
drop policy if exists "comments delete" on public.task_comments;
create policy "comments delete" on public.task_comments for delete
  using (user_id = auth.uid() or public.is_admin());

-- Table access for signed-in users (needed if "Automatically expose new tables"
-- was turned off). Row level security above still decides which rows they see.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.events, public.event_exceptions,
  public.tasks, public.task_claims, public.task_comments
  to authenticated;
grant execute on function public.is_member(), public.is_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime (live updates)
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['profiles','events','event_exceptions','tasks','task_claims','task_comments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
