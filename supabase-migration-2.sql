-- Ozu Tourism Club App — migration 2: notes, task tags, repeating tasks, event tasks
-- Run once in Supabase Dashboard > SQL Editor, after supabase-setup.sql.
-- Safe to run again: everything uses "if not exists" / "or replace" / "drop ... if exists".

-- ---------------------------------------------------------------------------
-- Notes
-- ---------------------------------------------------------------------------
create table if not exists public.notes (
  id uuid primary key default gen_random_uuid(),
  title text not null default '',
  body text not null default '' check (char_length(body) <= 50000),
  visibility text not null default 'private' check (visibility in ('private','members','people')),
  readers_can_edit boolean not null default false,
  author_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.note_shares (
  note_id uuid not null references public.notes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (note_id, user_id)
);

create table if not exists public.note_hidden (
  note_id uuid not null references public.notes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  primary key (note_id, user_id)
);

-- Admins get no extra access to notes: private means private.
create or replace function public.can_read_note(n_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.notes n
    where n.id = n_id and public.is_member() and (
      n.author_id = auth.uid()
      or n.visibility = 'members'
      or (n.visibility = 'people' and exists (select 1 from public.note_shares s where s.note_id = n.id and s.user_id = auth.uid()))
    )
  );
$$;

create or replace function public.can_edit_note(n_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_read_note(n_id) and exists (
    select 1 from public.notes n where n.id = n_id and (n.author_id = auth.uid() or n.readers_can_edit)
  );
$$;

create or replace function public.protect_note()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.author_id <> auth.uid() and
     (new.visibility, new.readers_can_edit, new.author_id) is distinct from (old.visibility, old.readers_can_edit, old.author_id) then
    raise exception 'Only the author can change who sees or edits this note';
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

drop trigger if exists protect_note on public.notes;
create trigger protect_note before update on public.notes
  for each row execute function public.protect_note();

alter table public.notes enable row level security;
alter table public.note_shares enable row level security;
alter table public.note_hidden enable row level security;

drop policy if exists "notes read" on public.notes;
create policy "notes read" on public.notes for select using (public.can_read_note(id));
drop policy if exists "notes insert" on public.notes;
create policy "notes insert" on public.notes for insert
  with check (public.is_member() and author_id = auth.uid());
drop policy if exists "notes update" on public.notes;
create policy "notes update" on public.notes for update
  using (public.can_edit_note(id)) with check (true);
drop policy if exists "notes delete" on public.notes;
create policy "notes delete" on public.notes for delete
  using (author_id = auth.uid() or (public.is_admin() and visibility = 'members'));

drop policy if exists "note shares read" on public.note_shares;
create policy "note shares read" on public.note_shares for select
  using (user_id = auth.uid() or exists (select 1 from public.notes n where n.id = note_id and n.author_id = auth.uid()));
drop policy if exists "note shares write" on public.note_shares;
create policy "note shares write" on public.note_shares for all
  using (exists (select 1 from public.notes n where n.id = note_id and n.author_id = auth.uid()))
  with check (exists (select 1 from public.notes n where n.id = note_id and n.author_id = auth.uid()));

drop policy if exists "note hidden own" on public.note_hidden;
create policy "note hidden own" on public.note_hidden for all
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_read_note(note_id));

-- ---------------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------------
create table if not exists public.tags (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 30),
  color text,
  created_at timestamptz not null default now()
);
create unique index if not exists tags_name_unique on public.tags (lower(name));

create table if not exists public.task_tags (
  task_id uuid not null references public.tasks(id) on delete cascade,
  tag_id uuid not null references public.tags(id) on delete cascade,
  primary key (task_id, tag_id)
);

alter table public.tags enable row level security;
alter table public.task_tags enable row level security;

drop policy if exists "tags read" on public.tags;
create policy "tags read" on public.tags for select using (public.is_member());
drop policy if exists "tags admin" on public.tags;
create policy "tags admin" on public.tags for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "task tags read" on public.task_tags;
create policy "task tags read" on public.task_tags for select using (public.is_member());
drop policy if exists "task tags write" on public.task_tags;
create policy "task tags write" on public.task_tags for all
  using (exists (select 1 from public.tasks t where t.id = task_id and (t.created_by = auth.uid() or public.is_admin())))
  with check (exists (select 1 from public.tasks t where t.id = task_id and (t.created_by = auth.uid() or public.is_admin())));

-- ---------------------------------------------------------------------------
-- Repeating tasks
-- ---------------------------------------------------------------------------
alter table public.tasks add column if not exists repeat jsonb;
alter table public.tasks add column if not exists series_id uuid;
alter table public.tasks add column if not exists occurrence int not null default 1;
create unique index if not exists tasks_series_due_unique on public.tasks (series_id, due_date) where series_id is not null;
-- One copy per step of a series: a done task can be advanced only once.
create unique index if not exists tasks_series_occurrence_unique on public.tasks (series_id, occurrence) where series_id is not null;

-- Claimers may still only change status and position.
create or replace function public.protect_task()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or old.created_by = auth.uid() or public.is_admin() then return new; end if;
  if (new.title, new.description, new.due_date, new.priority, new.slots, new.event_id, new.event_date, new.created_by, new.repeat, new.series_id, new.occurrence)
     is distinct from
     (old.title, old.description, old.due_date, old.priority, old.slots, old.event_id, old.event_date, old.created_by, old.repeat, old.series_id, old.occurrence) then
    raise exception 'Only the creator or an admin can edit this task';
  end if;
  return new;
end $$;

-- Creates the next copy of a repeating task. Keeps the original creator,
-- copies tags and claims. Returns null if that copy already exists.
create or replace function public.create_next_task_copy(p_task_id uuid, p_due date, p_event_date date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  src public.tasks%rowtype;
  new_id uuid := gen_random_uuid();
  max_pos double precision;
begin
  select * into src from public.tasks where id = p_task_id;
  if not found or src.repeat is null then return null; end if;
  if not public.is_member() or not (
       src.created_by = auth.uid() or public.is_admin()
       or exists (select 1 from public.task_claims c where c.task_id = src.id and c.user_id = auth.uid())) then
    raise exception 'NO_PERMISSION';
  end if;
  -- Only a finished task can be advanced, only forward in time (max 2 years),
  -- and only once (the unique (series_id, occurrence) index enforces that).
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
                              position, created_by, repeat, series_id, occurrence)
    values (new_id, src.title, src.description, p_due, src.priority, 'todo', src.slots, src.event_id, p_event_date,
            max_pos + 1, src.created_by, src.repeat, coalesce(src.series_id, src.id), src.occurrence + 1);
  exception when unique_violation then
    return null;
  end;
  insert into public.task_tags (task_id, tag_id) select new_id, tag_id from public.task_tags where task_id = src.id;
  insert into public.task_claims (task_id, user_id)
    select new_id, user_id from public.task_claims where task_id = src.id order by claimed_at limit src.slots;
  return new_id;
end $$;

grant execute on function public.create_next_task_copy(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Claims for other people (task creator or admin may assign members)
-- ---------------------------------------------------------------------------
drop policy if exists "claims insert" on public.task_claims;
create policy "claims insert" on public.task_claims for insert
  with check (public.is_member() and (
    user_id = auth.uid() or public.is_admin()
    or exists (select 1 from public.tasks t where t.id = task_id and t.created_by = auth.uid())));
drop policy if exists "claims delete" on public.task_claims;
create policy "claims delete" on public.task_claims for delete
  using (user_id = auth.uid() or public.is_admin()
    or exists (select 1 from public.tasks t where t.id = task_id and t.created_by = auth.uid()));

-- ---------------------------------------------------------------------------
-- Access and live updates
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on
  public.notes, public.note_shares, public.note_hidden, public.tags, public.task_tags
  to authenticated;
grant execute on function public.can_read_note(uuid), public.can_edit_note(uuid) to authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['notes','note_shares','note_hidden','tags','task_tags'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
