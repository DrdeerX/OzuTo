# Club Positions, Teams and Team Tasks — Design Spec

Date: 2026-10-14
Status: Approved 2026-10-14
Builds on: `2026-10-13-club-app-design.md`, `2026-10-13-notes-tags-repeating-tasks-design.md`

## 1. Goals
- Model the club's positions: President, Vice President, Head of Finance, Head of Events and Organisation, Head of Media.
- Three teams (Finance, Events and Organisation, Media), each led by its head.
- Heads manage their team's members and give work to the whole team. Team work is visible only to that team, its head, the President and the Vice President.

## 2. Data
New columns on `profiles`:
- `position text` — one of `president`, `vice_president`, `head_finance`, `head_events`, `head_media`, or null. Unique (one holder per position).
- `team text` — one of `finance`, `events`, `media`, or null. A member is in at most one team.

New column on `tasks`:
- `team text` — null for club-wide tasks, or the team the task belongs to.

Mapping: `head_finance` → `finance`, `head_events` → `events`, `head_media` → `media`. Setting a head position also puts that person in the team.

## 3. Permissions (enforced in the database)
- `is_admin()` is true for `role = 'admin'` **or** `position in ('president','vice_president')`. The President and VP therefore get every admin power.
- `my_team()` returns the caller's team; `head_of()` returns the team the caller heads (or null).
- `can_see_team(t)`: `t is null`, or caller is admin, or caller's team is `t`.
- Profile changes (trigger `protect_profile`):
  - `position`: only admins; nobody changes their own position.
  - `team`: admins may set any value. A head may set `team` to their own team only on a member whose team is null and who is not pending, and may set it back to null only on members of their own team (not on themselves).
  - Removing a head position does not remove the person from the team.
- Tasks:
  - Select: `is_member()` and `can_see_team(team)`.
  - Insert: club-wide as before; team task only when caller is admin or head of that team.
  - Update/delete: as before, plus the head of the task's team.
  - `protect_task`: the head of the task's team may edit all fields; claimers still only status/position. Moving a task to another team requires admin or being head of both.
- Claims on team tasks: only members of that team (or admins) can be claimed.
- `task_claims`, `task_tags`, `task_comments` select only when the parent task is visible (subquery through `tasks`, which applies its own RLS).
- `create_next_task_copy` copies `team` and allows the team's head.

## 4. UI
- New sidebar tab **Ekipler / Teams** (all members):
  - Top: President and Vice President cards.
  - One section per team: head, then members.
  - President/VP (admins): a position picker on each position (dropdown of approved members); "Remove from team" on any member; "Add member" on any team.
  - Head: "Add member" (dropdown of approved members with no team) and "Remove" on their own team.
- Members screen and sidebar show a member's position or team label.
- Task form: **Team** field — "Club-wide" or one of the teams the caller may assign (admins: all; head: own team). Editing a team task keeps the field limited the same way.
- Board and list: team tasks show a team label; new **Team** filter ("Any team", each visible team).
- Team claim picker ("Add person") lists only team members for team tasks.

## 5. Migration
`supabase-migration-3.sql`, safe to re-run. Must run before the app update is published.

## 6. Testing (demo mode)
1. A Media member does not see Finance team tasks or their comments; the Finance head does; the President and VP see all.
2. A head can add an unteamed member to their team and remove them; cannot add a member of another team; cannot change positions.
3. President can appoint heads; appointing a head puts them in the team; nobody can change their own position.
4. President/VP get admin screens (Members, Manage tags).
5. Team task creation limited to head/admin; team members can claim; a non-team member cannot be added to a team task.
6. Earlier features (notes, tags, repeating tasks, recurrence self-test) still work.
