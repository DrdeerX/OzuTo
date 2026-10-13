-- ÖzüTo — migration 3: club positions, teams and team tasks
-- Run once in Supabase Dashboard > SQL Editor, after supabase-migration-2.sql.
-- Safe to run again.

-- ---------------------------------------------------------------------------
-- Positions and teams on profiles
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists position text;
alter table public.profiles add column if not exists team text;
do $$
begin
  alter table public.profiles add constraint profiles_position_check
    check (position in ('president','vice_president','head_finance','head_events','head_media'));
exception when duplicate_object then null;
end $$;
do $$
begin
  alter table public.profiles add constraint profiles_team_check check (team in ('finance','events','media'));
exception when duplicate_object then null;
end $$;
create unique index if not exists profiles_position_unique on public.profiles (position) where position is not null;

alter table public.tasks add column if not exists team text;
do $$
begin
  alter table public.tasks add constraint tasks_team_check check (team in ('finance','events','media'));
exception when duplicate_object then null;
end $$;

-- President and Vice President are admins.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid()
    and (role = 'admin' or (role <> 'pending' and position in ('president','vice_president'))));
$$;

-- The team the caller leads (null if not a head).
create or replace function public.head_of()
returns text language sql stable security definer set search_path = public as $$
  select case position when 'head_finance' then 'finance' when 'head_events' then 'events' when 'head_media' then 'media' end
  from public.profiles where id = auth.uid() and role <> 'pending';
$$;

create or replace function public.my_team()
returns text language sql stable security definer set search_path = public as $$
  select team from public.profiles where id = auth.uid() and role <> 'pending';
$$;

create or replace function public.can_see_team(t text)
returns boolean language sql stable security definer set search_path = public as $$
  select t is null or public.is_admin() or t = public.my_team() or t = public.head_of();
$$;

create or replace function public.user_in_team(u uuid, t text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = u and role <> 'pending' and (team = t or position = 'head_' || t));
$$;

-- Role, position and team rules.
create or replace function public.protect_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  my_head text;
  i_am_role_admin boolean;
begin
  -- a head position always comes with its team
  if new.position is distinct from old.position and new.position like 'head_%' then
    new.team := substr(new.position, 6);
  elsif new.position is distinct from old.position and new.position in ('president','vice_president') then
    new.team := null;   -- President and Vice President have no team
  end if;
  if auth.uid() is null then return new; end if;   -- SQL editor
  -- On someone else's profile, a team head (not admin) may only change the team.
  if old.id <> auth.uid() and not public.is_admin()
     and (to_jsonb(new) - 'team') is distinct from (to_jsonb(old) - 'team') then
    raise exception 'Team heads can only change team membership';
  end if;
  if new.username is distinct from old.username then
    raise exception 'Username cannot be changed';
  end if;
  if new.role is distinct from old.role then
    if not public.is_admin() then raise exception 'Only admins can change roles'; end if;
    if old.id = auth.uid() then raise exception 'You cannot change your own role'; end if;
  end if;
  if new.position is distinct from old.position then
    if not public.is_admin() then raise exception 'Only the President or Vice President can change positions'; end if;
    select role = 'admin' into i_am_role_admin from public.profiles where id = auth.uid();
    if old.id = auth.uid() and not coalesce(i_am_role_admin, false) then
      raise exception 'You cannot change your own position';
    end if;
    if new.position is not null and old.role = 'pending' then
      raise exception 'Approve this member first';
    end if;
  elsif new.team is distinct from old.team and not public.is_admin() then
    my_head := public.head_of();
    if my_head is null then raise exception 'Only a team head can change team members'; end if;
    if old.id = auth.uid() then raise exception 'You cannot change your own team'; end if;
    if not ((old.team is null and new.team = my_head and old.role <> 'pending' and old.position is null)
            or (old.team = my_head and new.team is null)) then
      raise exception 'You can only manage your own team';
    end if;
  end if;
  return new;
end $$;

drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles for update
  using (id = auth.uid() or public.is_admin() or public.head_of() is not null)
  with check (true);

-- ---------------------------------------------------------------------------
-- Team tasks
-- ---------------------------------------------------------------------------
drop policy if exists "tasks read" on public.tasks;
create policy "tasks read" on public.tasks for select
  using (public.is_member() and public.can_see_team(team));
drop policy if exists "tasks insert" on public.tasks;
create policy "tasks insert" on public.tasks for insert
  with check (public.is_member() and created_by = auth.uid()
    and (team is null or public.is_admin() or team = public.head_of()));
drop policy if exists "tasks update" on public.tasks;
create policy "tasks update" on public.tasks for update
  using (public.is_member() and public.can_see_team(team) and (
    created_by = auth.uid() or public.is_admin()
    or (team is not null and team = public.head_of())
    or exists (select 1 from public.task_claims c where c.task_id = id and c.user_id = auth.uid())));
drop policy if exists "tasks delete" on public.tasks;
create policy "tasks delete" on public.tasks for delete
  using (created_by = auth.uid() or public.is_admin() or (team is not null and team = public.head_of()));

create or replace function public.protect_task()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  h text;
begin
  if auth.uid() is null then return new; end if;
  h := public.head_of();
  if new.team is distinct from old.team and not (
       public.is_admin() or (h is not null and coalesce(new.team, h) = h and coalesce(old.team, h) = h)) then
    raise exception 'Only the team head or an admin can move a task between teams';
  end if;
  if old.created_by = auth.uid() or public.is_admin() or (old.team is not null and old.team = h) then return new; end if;
  if (new.title, new.description, new.due_date, new.priority, new.slots, new.event_id, new.event_date, new.created_by, new.repeat, new.series_id, new.occurrence, new.team)
     is distinct from
     (old.title, old.description, old.due_date, old.priority, old.slots, old.event_id, old.event_date, old.created_by, old.repeat, old.series_id, old.occurrence, old.team) then
    raise exception 'Only the creator or an admin can edit this task';
  end if;
  return new;
end $$;

-- Claims, tags and comments follow the visibility of their task
-- (the subquery on tasks runs under the caller's own row level security).
drop policy if exists "claims read" on public.task_claims;
create policy "claims read" on public.task_claims for select
  using (exists (select 1 from public.tasks t where t.id = task_id));
drop policy if exists "claims insert" on public.task_claims;
create policy "claims insert" on public.task_claims for insert
  with check (public.is_member()
    and exists (select 1 from public.tasks t where t.id = task_id and (
      t.team is null or public.user_in_team(user_id, t.team) or (user_id = auth.uid() and public.is_admin())))
    and (user_id = auth.uid() or public.is_admin()
      or exists (select 1 from public.tasks t where t.id = task_id
        and (t.created_by = auth.uid() or (t.team is not null and t.team = public.head_of())))));
drop policy if exists "claims delete" on public.task_claims;
create policy "claims delete" on public.task_claims for delete
  using (user_id = auth.uid() or public.is_admin()
    or exists (select 1 from public.tasks t where t.id = task_id
      and (t.created_by = auth.uid() or (t.team is not null and t.team = public.head_of()))));

drop policy if exists "task tags read" on public.task_tags;
create policy "task tags read" on public.task_tags for select
  using (exists (select 1 from public.tasks t where t.id = task_id));
drop policy if exists "task tags write" on public.task_tags;
create policy "task tags write" on public.task_tags for all
  using (exists (select 1 from public.tasks t where t.id = task_id and (t.created_by = auth.uid() or public.is_admin() or (t.team is not null and t.team = public.head_of()))))
  with check (exists (select 1 from public.tasks t where t.id = task_id and (t.created_by = auth.uid() or public.is_admin() or (t.team is not null and t.team = public.head_of()))));

drop policy if exists "comments read" on public.task_comments;
create policy "comments read" on public.task_comments for select
  using (public.is_member() and exists (select 1 from public.tasks t where t.id = task_id));
drop policy if exists "comments insert" on public.task_comments;
create policy "comments insert" on public.task_comments for insert
  with check (public.is_member() and user_id = auth.uid() and exists (select 1 from public.tasks t where t.id = task_id));

-- Next copy of a repeating task: also allowed for the team head, keeps the team.
create or replace function public.create_next_task_copy(p_task_id uuid, p_due date, p_event_date date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  src public.tasks%rowtype;
  new_id uuid := gen_random_uuid();
  max_pos double precision;
begin
  select * into src from public.tasks where id = p_task_id;
  if not found or src.repeat is null then return null; end if;
  if not public.is_member() or not public.can_see_team(src.team) or not (
       src.created_by = auth.uid() or public.is_admin()
       or (src.team is not null and src.team = public.head_of())
       or exists (select 1 from public.task_claims c where c.task_id = src.id and c.user_id = auth.uid())) then
    raise exception 'NO_PERMISSION';
  end if;
  if src.status <> 'done' or src.due_date is null or p_due is null
     or p_due <= src.due_date or p_due > src.due_date + 731 then
    raise exception 'INVALID_NEXT_COPY';
  end if;
  if src.repeat ? 'end' and src.repeat->'end'->>'type' = 'count'
     and src.occurrence >= coalesce((src.repeat->'end'->>'count')::int, 1) then
    return null;
  end if;
  if src.repeat ? 'end' and src.repeat->'end'->>'type' = 'until'
     and p_due > (src.repeat->'end'->>'date')::date then
    return null;
  end if;
  select coalesce(max(position), 0) into max_pos from public.tasks where status = 'todo';
  begin
    insert into public.tasks (id, title, description, due_date, priority, status, slots, event_id, event_date,
                              position, created_by, repeat, series_id, occurrence, team)
    values (new_id, src.title, src.description, p_due, src.priority, 'todo', src.slots, src.event_id, p_event_date,
            max_pos + 1, src.created_by, src.repeat, coalesce(src.series_id, src.id), src.occurrence + 1, src.team);
  exception when unique_violation then
    return null;
  end;
  insert into public.task_tags (task_id, tag_id) select new_id, tag_id from public.task_tags where task_id = src.id;
  insert into public.task_claims (task_id, user_id)
    select new_id, user_id from public.task_claims where task_id = src.id order by claimed_at limit src.slots;
  return new_id;
end $$;

grant execute on function public.head_of(), public.my_team(), public.can_see_team(text), public.user_in_team(uuid, text) to authenticated;
