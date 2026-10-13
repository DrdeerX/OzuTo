# Notes, Task Tags, Repeating Tasks, Event Tasks — Design Spec

Date: 2026-10-13
Status: Approved 2026-10-13
Builds on: `2026-10-13-club-app-design.md`

## 1. Goals

1. A **Notes** tab where members write notes for themselves, for all members, or for chosen people. The author decides whether readers may edit.
2. **Tags** for tasks. Admins manage the tag list; tasks can be searched and filtered by tag.
3. **Repeating tasks**: a repeat section in the task form. When a repeating task is marked done, the next copy is created.
4. **Event → task**: when creating an event, optionally create a linked task with chosen people already assigned. For a repeating event, the task follows the event's dates.

All UI follows the passport theme and the TR/EN dictionary. All new tables get RLS and Realtime.

## 2. Notes

### 2.1 Data
Table `notes`:
- `id uuid` primary key
- `title text` not null (may be empty string → shown as "Untitled")
- `body text` not null default '' (max 50,000 characters)
- `visibility text` not null default `'private'`, check in (`private`, `members`, `people`)
- `readers_can_edit boolean` not null default false
- `author_id uuid` references `profiles(id)` on delete cascade, default `auth.uid()`
- `updated_by uuid` references `profiles(id)` on delete set null
- `created_at`, `updated_at timestamptz` default now()

Table `note_shares` (used only when `visibility = 'people'`):
- `note_id uuid` references `notes(id)` on delete cascade
- `user_id uuid` references `profiles(id)` on delete cascade
- primary key (`note_id`, `user_id`)

Helper `can_read_note(note)` / `can_edit_note(note)` (SQL functions, security definer):
- read: author, or (`members` and `is_member()`), or (`people` and caller is in `note_shares`). Admins get **no** extra read access: private notes stay private.
- edit: author, or (`readers_can_edit` and read is allowed).

### 2.2 Rules
- Select: `can_read_note`.
- Insert: `is_member()` and `author_id = auth.uid()`.
- Update: `can_edit_note`. A `before update` trigger:
  - rejects changes to `visibility`, `readers_can_edit`, `author_id` unless caller is the author;
  - sets `updated_at = now()` and `updated_by = auth.uid()`.
- Delete: author, or admin for notes visible to all members (moderation).
- `note_shares` insert/delete: note author. Select: author or the shared user.

Private notes are filtered by the database, so they never reach other members' browsers, admins included.

### 2.2a Hiding notes
Table `note_hidden`: `note_id` → `notes` on delete cascade, `user_id` default `auth.uid()`, primary key (`note_id`, `user_id`). Each user reads/writes only their own rows.
- Every note (own or shared) has a **Hide** action. Hidden notes leave that user's lists; nobody else is affected.
- Filter **Hidden** lists them, with **Unhide**.

### 2.3 Concurrent edits
Save sends `update ... where id = X and updated_at = <value when opened>`. If no row is updated (someone else saved first), the app shows "This note was changed by <name> — reload" and keeps the user's text in the editor so it can be copied. Realtime refreshes an open note in view mode automatically; in edit mode it only shows the "changed" banner.

### 2.4 UI
- New sidebar item **Notlar / Notes** (between Tasks and Members).
- Desktop: two columns — note list (left, 300px) and open note (right). Phone: list screen, then note screen with a back button.
- List: search box (title + body), filter segment **All / Mine / Shared with me / Hidden**, sorted by `updated_at` desc. Each row: title, first line of body, visibility icon (lock / people / globe), "edited 2h ago".
- Note view: title (serif), visibility badge, "Last edited by X · date", rendered body.
- Note edit: title input, body textarea, **Edit / View** toggle, Save button (also Ctrl+S).
- Note settings (author only), in a small panel above the body:
  - Visibility: Only me / All members / Chosen people (+ member picker with checkboxes).
  - Switch: **Readers can edit**.
  - Delete note.
- New note button creates a private note and opens it in edit mode.

### 2.5 Formatting (rendered in view mode)
Line-based, escaped first, then:
- `# `, `## ` → headings
- `- ` → bullet list
- `[ ] ` / `[x] ` at line start → checkbox; clicking it toggles the character in the body and saves (only if the viewer can edit)
- `**text**` → bold
- URLs starting with `http(s)://` → links (open in new tab, `rel="noopener"`)
No HTML is ever passed through.

## 3. Tags

### 3.1 Data
Table `tags`: `id uuid` pk, `name text` not null unique (case-insensitive, max 30), `color text` (one of the event colour keys), `created_at`.
Table `task_tags`: `task_id` → `tasks` on delete cascade, `tag_id` → `tags` on delete cascade, primary key (`task_id`, `tag_id`).

### 3.2 Rules
- `tags`: select `is_member()`; insert/update/delete `is_admin()`.
- `task_tags`: select `is_member()`; insert/delete when the caller may edit the task (task creator or admin).

### 3.3 UI
- Tasks screen header: **Manage tags** button (admins only) opens a modal: list of tags with colour swatch, rename, recolour, delete (confirm: "Removes this tag from N tasks"), and an add row.
- Task form: **Tags** field — tag chips that toggle on/off.
- Board cards and list rows show tags as small mono labels with a colour bar.
- Filters row: a **search box** (matches title, description, and tag names; case- and Turkish-accent-insensitive via `toLocaleLowerCase('tr')`), plus a **tag dropdown**. Clicking a tag label on a card sets that tag filter.

## 4. Repeating tasks

### 4.1 Data
New columns on `tasks`:
- `repeat jsonb` — same rule format as events (`freq`, `interval`, `byweekday`, `monthlyMode`, `nth`, `end`), or `{ "followEvent": true }` for event tasks (section 5). Null = not repeating.
- `series_id uuid` — shared by all copies of one repeating task (first copy: its own id).
- `occurrence int` — 1 for the first copy, then 2, 3, ... (used for `count` endings).
- unique (`series_id`, `due_date`) — guarantees only one next copy, even if two people mark it done at once.

### 4.2 Behaviour
- Task form gets a **Repeat** section (same controls as the event form). Repeat needs a due date; the form says so if it is missing.
- When a repeating task's status changes to **Done** (from the board, list, or detail panel), the app:
  1. computes the next date after the current `due_date` using `ruleDates` (for `followEvent`: the next non-cancelled occurrence of the linked event after `event_date`);
  2. stops if the rule has ended (`until` passed or `occurrence` reached `count`);
  3. inserts the next copy: status `todo`, same title, description, priority, slots, repeat, event link, tags; `occurrence + 1`; new `due_date` (and `event_date` for event tasks);
  4. copies the claims (same people), within the slot limit;
  5. ignores a unique-constraint error (another member already created it).
- Moving a done task back to To do / In progress does **not** delete the next copy.
- Editing the repeat rule changes only that copy; the next copy inherits the rule at the moment it is created.
- Task cards show a small repeat icon; the detail panel shows the rule text.

### 4.2a Creating the next copy
The app computes the next date (same recurrence code as events) and calls a database function `create_next_task_copy(task_id, next_due, next_event_date)`. The function (security definer) checks that the caller may move the task, inserts the copy keeping the original creator, copies tags and claims, and returns null instead of failing when the copy already exists.

### 4.3 Claims for other people
`task_claims` insert rule changes to: caller is the user being claimed **or** caller is the task creator **or** admin. Delete stays: own claim or admin, plus task creator.

## 5. Event → task

### 5.1 UI
Event form (new events only) gets a section:
- ☐ **Also make a task**
- When ticked: member picker (checkboxes, with search), and priority.

### 5.2 Behaviour
On save, after the event is created:
- Insert a task: title = event title, description = event description, `due_date` = date of the first occurrence, `event_id` = new event, `event_date` = first occurrence date for repeating events (null for one-time), `slots` = number of picked people (minimum 1), priority as chosen.
- For a repeating event: `repeat = { followEvent: true }`, `series_id` = task id, `occurrence = 1`.
- Insert claims for each picked person.
- Picked people see the task under **My tasks**.

Known limit (accepted): with "next copy after done", if nobody marks a meeting task done, no task appears for the next meeting.

## 6. Realtime and loading
- Add `notes`, `note_shares`, `tags`, `task_tags` to the `supabase_realtime` publication.
- Load `tags` and `task_tags` with the other tables after sign-in. Load `notes` and `note_shares` when the Notes tab is first opened, then keep them live.

## 7. Database migration
A new file `supabase-migration-2.sql`, safe to run more than once (uses `if not exists` / `drop policy if exists`). A fresh project runs `supabase-setup.sql` and then `supabase-migration-2.sql`.

## 8. Testing
Demo mode gets sample notes, tags and a repeating task. Checks:
1. Notes: private note invisible to another demo user (admin included); hide/unhide affects only the current user; members note visible; chosen-people note visible only to chosen; readers-can-edit off blocks edits, on allows them; non-author cannot change visibility; stale-save banner appears.
2. Formatting: headings, bullets, checkbox toggle, bold, links; `<script>` in a note shows as text.
3. Tags: admin creates/renames/deletes; non-admin sees no Manage button; search by tag name and by Turkish text (e.g. "afis" finds "Afiş").
4. Repeating task: mark done → next copy with next date, same claimers, same tags; double "done" creates one copy; `count` end stops copies.
5. Event task: one-time event with 2 people → task with 2/2 claimed; weekly event → done creates copy for next meeting and skips a cancelled date.
6. Recurrence self-test still passes; TR/EN and both themes checked on the new screens.

## 9. Out of scope
- Rich text editor (WYSIWYG), images or files in notes.
- Comments on notes.
- Version history of notes.
- Automatic creation of meeting tasks without marking done.
