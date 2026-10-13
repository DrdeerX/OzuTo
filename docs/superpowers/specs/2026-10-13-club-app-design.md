# Ozu Tourism Club App — Design Spec

Date: 2026-10-13
Status: Draft, awaiting review

## 1. Purpose

A Notion-style web app for the Ozu Tourism Club (Uluslararası Otelcilik ve Turizm Kulübü). Club members sign in, see a shared club schedule, and organise work through a shared task board where they create and claim tasks. More screens will be added later.

Success criteria:
- Members sign in with username + password, same flow as the Classwork Organizer.
- New sign-ups cannot see club data until an admin approves them.
- Schedule supports one-time events and full calendar-style repeating events, with per-date edits.
- Tasks support multiple volunteers, priority, event links, a Kanban board, and comments.
- All data is shared between members and updates live.
- UI is available in Turkish and English with a switch.
- Hosted on GitHub Pages under the `DrdeerX` account.

## 2. Decisions taken

| Topic | Decision |
|---|---|
| Access model | Open sign-up, admin approval required; admins can delete any event/task |
| Backend | New, separate Supabase project (not the Organizer's project) |
| Code structure | Single `index.html` file, like the Organizer |
| Recurrence | Full calendar style (intervals, multiple weekdays, nth-weekday monthly, end rules) with per-date edits |
| Tasks | Multiple volunteers, priority, event link, Kanban board, comments |
| Language | Turkish + English, switchable |
| Hosting | GitHub Pages, repo e.g. `DrdeerX/ozu-tourism-club` |

## 3. Files

```
Ozu Tourism Club/Club App/
  index.html              # whole app: HTML + CSS + JS
  supabase-setup.sql      # run once in the Supabase SQL editor
  .claude/launch.json     # local preview server (python -m http.server)
  docs/superpowers/specs/ # this spec
```

External dependency: `@supabase/supabase-js@2` UMD build from jsDelivr, same as the Organizer. No build step.

## 4. Look and feel

- Reuse the Organizer's design tokens (CSS variables for light and dark themes, dark sidebar, accent `#6a5cff`), radius, shadows, and system font stack.
- Layout: left sidebar with screen links (Schedule, Tasks, Members for admins), user name, language switch, theme toggle, sign-out. Content area on the right.
- Mobile: sidebar collapses into a top bar with a menu button. Page must work at 375px width.

## 5. Internationalisation

- One `I18N` object: `{ tr: {key: text}, en: {key: text} }`. All UI text is read through `t(key)`.
- Elements with static text use a `data-i18n="key"` attribute and are re-filled when the language changes.
- Weekday and month names come from `Intl.DateTimeFormat` with locale `tr-TR` or `en-GB`.
- Language choice is stored in `localStorage` (wrapped in try/catch); default is Turkish.
- The TR / EN switch appears on the login screen and in the sidebar.

## 6. Authentication and roles

### 6.1 Sign-in and sign-up screens
Users never see or type an email address. Only username and password.

**Sign-in screen** (styled like the Organizer login):
- Fields: username, password. Button: Sign in. Error line. Enter-key submit.
- Link at the bottom: "No account? Sign up", which opens the sign-up screen.

**Sign-up screen** (separate screen, same style):
- Fields: username, password, repeat password. Button: Sign up. Error line.
- Link at the bottom: "Have an account? Sign in", which goes back to the sign-in screen.
- Checks before sending: username rule `^[a-zA-Z0-9_.-]{3,}$`, password at least 6 characters, both passwords match, username not already taken (Supabase error is translated to "This username is taken").
- After a successful sign-up the user stays signed in and goes straight to the waiting screen: "Waiting for an admin to accept your membership" (see 6.3).

**Internal detail (invisible to users):** Supabase Auth needs an email-shaped login, so the app turns the username into `<lowercased username>@ozu-tourism-club.local` before calling Supabase. This address never appears in the UI and receives no mail. Supabase project setting required: email confirmation turned off. The setup notes must say this.

### 6.2 Profiles and roles
Table `profiles`:
- `id uuid` primary key, references `auth.users(id)` on delete cascade
- `username text` unique not null
- `display_name text` (defaults to username)
- `role text` not null default `'pending'`, check in (`pending`, `member`, `admin`)
- `created_at timestamptz` default now()

A trigger on `auth.users` insert creates the profile row with role `pending`, reading `username` from `raw_user_meta_data`.

Helper functions (`security definer`, stable):
- `is_member()` — true when the caller's role is `member` or `admin`.
- `is_admin()` — true when the caller's role is `admin`.

Profiles read rule: a user can always read their own row (needed for the waiting screen); members can read all rows.

Role protection: a `before update` trigger on `profiles` rejects a change to `role` unless `is_admin()` is true. Users may update their own `display_name` only.

First admin: after signing up, the owner runs:
```sql
update public.profiles set role = 'admin' where username = '<your username>';
```
(Run in the SQL editor, which bypasses the role trigger check because it runs as the `postgres` role; the trigger allows changes when `auth.uid()` is null.)

### 6.3 App states after sign-in
- `pending` — full-screen message "Waiting for an admin to accept your membership", with sign-out and a refresh button. Shown right after sign-up and on every later sign-in until approved. The screen also switches to the main app by itself when an admin approves (Realtime on the user's own profile row). No club data is loaded.
- `member` / `admin` — main app.
- No profile row — the user was rejected. Show "Your request was not approved" with sign-out. Rejection deletes the profile row (admin only); users cannot insert their own profile row, so they cannot re-apply without a new sign-up.

### 6.4 Members screen (admins only)
- Pending list: username, sign-up date, **Approve** / **Reject** buttons.
- Member list: username, display name, role; actions **Make admin**, **Make member**, **Remove** (sets role back to `pending`).
- An admin cannot demote or remove themselves (prevents locking out the last admin).

## 7. Schedule

### 7.1 Views
- Month grid (default), week view with hourly slots, list of upcoming events.
- Navigation: previous, Today, next. View switch buttons.
- Click empty day/slot: open "new event" form prefilled with that date/time.
- Click event: open detail panel (view, edit, delete, linked tasks).
- List view is the default on screens narrower than 640px.

### 7.2 Event fields
Table `events`:
- `id uuid` primary key default `gen_random_uuid()`
- `title text` not null
- `description text`
- `location text`
- `color text` (one of a fixed palette of 6 keys)
- `all_day boolean` default false
- `start_at timestamptz` not null — start of the first occurrence
- `end_at timestamptz` not null — end of the first occurrence (duration = end − start)
- `rrule jsonb` — null for one-time events, else the rule in 7.3
- `created_by uuid` references `profiles(id)` default `auth.uid()`
- `created_at timestamptz` default now()

All dates and times are calculated and shown in `Europe/Istanbul`.

### 7.3 Recurrence rule format
```json
{
  "freq": "daily" | "weekly" | "monthly" | "yearly",
  "interval": 1,
  "byweekday": [0-6],            // weekly only; 0 = Monday
  "monthlyMode": "day" | "nth",  // monthly only
  "nth": 1 | 2 | 3 | 4 | -1,     // monthly "nth" mode; -1 = last
  "end": { "type": "never" } | { "type": "until", "date": "YYYY-MM-DD" } | { "type": "count", "count": 10 }
}
```
- Monthly `day` mode uses the day number of `start_at`. Months without that day (e.g. the 31st) are skipped.
- Monthly `nth` mode uses the weekday of `start_at` (e.g. "first Monday", "last Friday").
- Yearly uses the month and day of `start_at`; 29 Feb is shown only in leap years.

### 7.4 Expansion
A pure function `expandEvent(event, exceptions, rangeStart, rangeEnd)` returns the occurrences inside the visible range:
- Each occurrence has `eventId`, `originalDate` (`YYYY-MM-DD` in Istanbul time), and the effective `title`, `description`, `location`, `start`, `end`.
- `count` endings are counted from the first occurrence, including cancelled dates.
- Exceptions are applied: cancelled dates are removed; overridden dates replace fields; an override may move the occurrence to another day.
- No occurrences are stored in the database.

### 7.5 Exceptions
Table `event_exceptions`:
- `id uuid` primary key
- `event_id uuid` references `events(id)` on delete cascade
- `original_date date` not null — which occurrence this changes
- `cancelled boolean` default false
- `title`, `description`, `location` (nullable text — null means "use the series value")
- `start_at`, `end_at` (nullable timestamptz)
- unique (`event_id`, `original_date`)

### 7.6 Editing and deleting a repeating event
When the user saves or deletes an occurrence of a repeating event, a dialog asks for the scope:
- **This event only** — upsert an exception for `original_date` (override fields, or `cancelled = true` for delete).
- **This and following events** —
  - Edit: set the old series' end to `until = original_date − 1 day`; insert a new series that starts at the edited occurrence with the new values and the old rule (with `count` reduced by the occurrences already used). Exceptions on or after `original_date` move to the new series when their `original_date` still matches an occurrence of the new rule; others are deleted.
  - Delete: set the old series' end to `until = original_date − 1 day` and delete exceptions on or after that date. If this removes every occurrence, delete the series.
- **All events** —
  - Edit: update the series row. Existing exceptions are kept. If the rule or start time changes, exceptions whose `original_date` is no longer an occurrence are deleted.
  - Delete: delete the series (exceptions cascade).

One-time events skip the dialog.

### 7.7 Permissions
- Read: `is_member()`.
- Insert: `is_member()`.
- Update / delete events and exceptions: event creator or `is_admin()`.

## 8. Tasks

### 8.1 Fields
Table `tasks`:
- `id uuid` primary key
- `title text` not null
- `description text`
- `due_date date`
- `priority text` default `'medium'`, check in (`low`, `medium`, `high`)
- `status text` default `'todo'`, check in (`todo`, `in_progress`, `done`)
- `slots int` not null default 1, check `slots between 1 and 50`
- `event_id uuid` references `events(id)` on delete set null
- `event_date date` — which occurrence of a repeating event the task is for (null for one-time events)
- `position double precision` — order within a Kanban column
- `created_by uuid` default `auth.uid()`
- `created_at timestamptz` default now()

### 8.2 Claims
Table `task_claims`:
- `task_id uuid` references `tasks(id)` on delete cascade
- `user_id uuid` references `profiles(id)` on delete cascade, default `auth.uid()`
- `claimed_at timestamptz` default now()
- primary key (`task_id`, `user_id`)

A `before insert` trigger locks the task row (`select ... for update`) and rejects the insert when the number of claims is already equal to `slots`. This stops over-claiming when two people click at the same time.

Rules:
- A member may insert a claim only for themselves.
- A member may delete their own claim (Unclaim). Admins may delete any claim.

### 8.3 Comments
Table `task_comments`:
- `id uuid` primary key
- `task_id uuid` references `tasks(id)` on delete cascade
- `user_id uuid` default `auth.uid()`
- `body text` not null, max 2000 characters
- `created_at timestamptz` default now()

Delete: author or admin. Comments are not editable.

### 8.4 Views
- Switch at the top: **Board** / **List**.
- **Board**: columns To do / In progress / Done. Cards show title, priority badge, due date, claimers' initials, "2/3" slot counter, linked event name. Drag and drop (HTML5 drag events) moves a card between columns and reorders it; the new `position` is the midpoint between neighbours. On touch screens, a long-press opens a "Move to…" menu instead.
- **List**: table with title, status, priority, due date, slots, linked event; sortable by clicking headers.
- Filters (both views): My tasks, Open spots, priority, linked event.
- **New task** button opens the task form.

### 8.5 Task detail panel
- All fields, claimers list, Claim / Unclaim button (Claim disabled and labelled "Full" when slots are filled), status control.
- Linked event: clicking it opens the Schedule at that date with the event selected.
- Comment thread (oldest first) with a text box at the bottom.

### 8.6 Permissions
- Read: `is_member()`.
- Insert task: `is_member()`.
- Change `status` or `position`: creator, a claimer, or admin.
- Edit other fields or delete: creator or admin.
- Enforced with RLS for update/delete plus a `before update` trigger that rejects changes to non-status fields by claimers who are not the creator or an admin.

### 8.7 Event ↔ task link
- The event detail panel lists tasks linked to that event (and that occurrence date, for repeating events), with a "New task for this event" button.
- In the task form, the event picker lists upcoming occurrences for the next 90 days.

## 9. Live updates

- Supabase Realtime enabled on `profiles`, `events`, `event_exceptions`, `tasks`, `task_claims`, `task_comments` (added to the `supabase_realtime` publication in the setup SQL).
- The app subscribes once after sign-in. On any change it updates its in-memory copy and re-renders the current screen. No full reload.

## 10. Data loading

- After sign-in as member/admin: load all `profiles`, `events`, `event_exceptions`, `tasks`, `task_claims` in parallel. Comments load when a task panel opens.
- Club data volume is small (hundreds of rows), so loading everything is acceptable.

## 11. Error handling

- Every Supabase call checks `error` and shows a toast with a short translated message plus the raw error text.
- A failed claim because the task is full shows "This task is already full".
- Permission errors show "You do not have permission to do this".
- If Supabase is not configured (placeholder URL), show the same setup message as the Organizer.
- If the network drops, Realtime reconnects automatically; the app shows an "Offline" badge while disconnected.

## 12. Testing

Manual, in the local preview server, against the real new Supabase project:
1. Sign up a new user, then confirm the pending screen and that no data loads.
2. Promote the first admin with SQL; approve a second user from the Members screen.
3. Confirm a member cannot change their own role (direct API call returns an error).
4. Create a one-time event, then daily, weekly (2 weekdays, every 2 weeks), monthly day, monthly nth/last, yearly, until, and count events. Check the dates in month, week, and list views.
5. Edit one occurrence (time and title), "this and following", and "all"; delete with each scope.
6. Create a task with 2 slots, claim it from two accounts, then confirm a third claim is refused.
7. Drag tasks between columns and reorder them; check the order after reload.
8. Add and delete comments; check that live updates appear in a second browser window.
9. Switch TR / EN on every screen; switch light/dark theme; check the 375px layout.

The recurrence expansion function also gets a small in-page self-test (run with `?selftest` in the URL) that checks known rule/date pairs and logs pass/fail to the console.

## 13. Out of scope (for now)

- Email or push notifications.
- File uploads.
- Additional Notion-style screens (notes/pages, wiki); to be specified later.
- Importing the club member list or student ID checks.
