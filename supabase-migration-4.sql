-- ÖzüTo — migration 4: "I forgot my password" requests approved by an admin
-- Run once in Supabase Dashboard > SQL Editor, after supabase-migration-3.sql.
-- Safe to run again.
--
-- How it works: on the sign-in screen a person enters their username and a new
-- password and gets a one-time code. Only bcrypt hashes of the password and the code
-- are stored. The person tells an admin the code; the admin types it on the Members
-- tab to approve. The new password then replaces the old one and the person's other
-- sessions are signed out. Nothing changes without an admin and the right code, so a
-- stranger who files (or overwrites) a request for someone else cannot get it approved.

create extension if not exists pgcrypto;

create table if not exists public.password_resets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pw_hash text not null,
  code_hash text,
  created_at timestamptz not null default now()
);

-- No direct table access at all: everything goes through the functions below.
alter table public.password_resets enable row level security;
revoke all on public.password_resets from anon, authenticated;

alter table public.password_resets add column if not exists code_hash text;
drop function if exists public.request_password_reset(text, text);
drop function if exists public.resolve_password_reset(uuid, boolean);

-- Anyone (signed out) can ask and gets back a one-time code. Unknown usernames get a
-- code too (nothing is stored), so the form does not reveal which usernames exist.
-- A new request replaces an older one, and with it the old code.
create or replace function public.request_password_reset(p_username text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid;
  code text := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
begin
  if p_password is null or char_length(p_password) < 6 or char_length(p_password) > 72 then
    raise exception 'Password must be 6 to 72 characters';
  end if;
  select id into u from public.profiles where username = lower(trim(p_username));
  if u is null then return code; end if;
  insert into public.password_resets (user_id, pw_hash, code_hash, created_at)
  values (u, crypt(p_password, gen_salt('bf', 10)), crypt(code, gen_salt('bf', 8)), now())
  on conflict (user_id) do update set pw_hash = excluded.pw_hash, code_hash = excluded.code_hash, created_at = excluded.created_at;
  return code;
end $$;

-- Admins: list open requests (never the hash).
create or replace function public.list_password_resets()
returns table (user_id uuid, username text, display_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NO_PERMISSION'; end if;
  return query
    select r.user_id, p.username, p.display_name, r.created_at
    from public.password_resets r join public.profiles p on p.id = r.user_id
    order by r.created_at;
end $$;

-- Admins: approve with the person's code (set the new password, sign them out
-- everywhere) or reject. A wrong code changes nothing and keeps the request.
create or replace function public.resolve_password_reset(p_user uuid, p_approve boolean, p_code text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare
  r public.password_resets%rowtype;
begin
  if not public.is_admin() then raise exception 'NO_PERMISSION'; end if;
  select * into r from public.password_resets where user_id = p_user for update;
  if not found then raise exception 'Request not found'; end if;
  if p_approve then
    if r.code_hash is null or p_code is null
       or crypt(upper(trim(p_code)), r.code_hash) <> r.code_hash then
      raise exception 'WRONG_CODE';
    end if;
    update auth.users set encrypted_password = r.pw_hash, updated_at = now() where id = p_user;
    delete from auth.sessions where user_id = p_user;
  end if;
  delete from public.password_resets where user_id = p_user;
end $$;

revoke all on function public.request_password_reset(text, text) from public;
revoke all on function public.list_password_resets() from public;
revoke all on function public.resolve_password_reset(uuid, boolean, text) from public;
grant execute on function public.request_password_reset(text, text) to anon, authenticated;
grant execute on function public.list_password_resets() to authenticated;
grant execute on function public.resolve_password_reset(uuid, boolean, text) to authenticated;
