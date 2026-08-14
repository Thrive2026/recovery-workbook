# Recovery Workbook — setup guide

A single-file interactive workbook app for **SUD**, **Mental Health**, and
**Comorbid** recovery tracks, built off your Individualized Action Plan
design system. Providers log in; clients never need an account. Progress
autosaves to Supabase so any provider on the team can pick a client's
workbook back up where the last person left off.

## Files
- `recovery-workbook.html` — the whole app (open this in a browser / host it)
- `supabase-schema.sql` — run once in your Supabase project's SQL editor
- this README

## 1. Set up Supabase
1. Use an existing Supabase project (your other hubs' project is fine) or spin up a new one.
2. Open **SQL Editor** and run all of `supabase-schema.sql`. It creates three tables — `providers`, `clients`, `workbook_progress` — with row-level security already turned on.
3. Go to **Authentication → Users → Add user** and create a login for each provider who will use the workbook (Thrive email + a temp password). No sign-up flow is exposed in the app on purpose — only staff you add manually can log in.

## 2. Connect the app
1. Open `recovery-workbook.html` in a text editor.
2. Near the top of the `<script>` block, find:
   ```js
   const CONFIG = {
     SUPABASE_URL: 'YOUR_SUPABASE_URL',
     SUPABASE_ANON_KEY: 'YOUR_SUPABASE_ANON_KEY'
   };
   ```
3. Replace both values with your project's URL and **anon/public** key (Supabase Dashboard → Project Settings → API). Never put the service-role key here — this file runs in the browser.
4. Save the file.

## 3. Host it
Same pattern as your other hubs — drop it wherever they live (static hosting, a shared drive link opened locally, etc.). No build step; it's one HTML file.

## How it works
- **Login** — providers sign in with email/password. Clients are never given credentials.
- **Dashboard** — search or add clients. Each client card shows a colored pill per track already in progress, with a live completion percentage.
- **Track picker** — pick SUD, Mental Health, or Comorbid for a client. If they've already started one, it's marked "in progress" and resumes exactly where they left off.
- **Workbook** — three chapters per track (Early / Middle / Late Recovery), each with plain-language reflection prompts, a relapse-prevention or wellness plan, goal setting (6-month/1-year/5-year/10-year), and a maintenance checklist. A sidebar progress ring and per-chapter checkmarks track completion.
- **My Resources & My People** — a fourth card next to the three tracks (also reachable from inside any workbook via the sidebar). Every Ohio statewide number (988, Crisis Text Line, National DV Hotline, 211) shows for every client. Below that, county-specific listings populate automatically based on the client's county — set once when you add the client, editable any time from the My Resources page itself. Counties without seeded listings yet show a plain "not filled in" note instead of guessing. Below that, a dynamic "My People" list where the client's own real support contacts (name, phone, relationship) get added, saved, and picked back up next session.
- **Autosave** — every answer saves ~1 second after you stop typing, as one JSON blob per client+track. No "save" button required, though one exists for peace of mind.
- **Read-aloud** — a 🔊 button on each reflection prompt uses the browser's built-in text-to-speech, useful for clients who read better by listening.
- **Export** — "Export this chapter (PDF)" turns the current chapter into a downloadable PDF; Print works too.
- **Crisis strip** — 988 / 911 / Crisis Text Line stay visible at the top of every workbook page, regardless of track.

## Extending it
- To add a fourth track or new chapters, copy one of the `TRACK_*` objects near the top of the script and adjust `TRACKS = {...}` at the bottom of that block.
- Prompt types available: `pLong` (paragraph answer), `pShort` (one line), `pList` (numbered fill-in-the-blank list), `pContacts` (name+phone rows), `pChecklist` (checkboxes), `pGoals` (goal/steps/barriers blocks by timeframe).
- If you later want per-provider audit history instead of a single shared JSON blob, split `workbook_progress.data` into a normalized `answers` table keyed by `(client_id, track, chapter_id, prompt_id)` — the schema note in the SQL file marks where that would slot in.

## A note on content
The reflection questions, relapse-prevention/wellness plan, and goal-setting structure are adapted from your uploaded Recovery Workbook (SUD track) and written in parallel for Mental Health and Comorbid at a 6th-grade reading level. Review the language for your population before rolling it out — you know your clients' reading level and vocabulary better than a first draft can.

## County-based resources
Every client gets a **county** (set when you add them, or any time from their My Resources page). The resources page always shows Ohio statewide numbers — 988, Crisis Text Line, National DV Hotline, 211 — since those work anywhere in the state. Below that, it shows county-specific listings *if* that county has been seeded with data.

As of August 2026, five regions are seeded, based on where Thrive has the most clients plus the Clark/Greene/Madison Warmline area:
- **Cuyahoga** County
- **Franklin** County
- **Summit** County
- **Mahoning / Trumbull / Columbiana** (the Mahoning Valley region shares crisis and food-bank services)
- **Clark / Greene / Madison** (shares the Mental Health Recovery Board's crisis line)

Every other county in the dropdown will show statewide numbers plus a plain "we don't have this county's listings yet" note — nothing is guessed or filled in with placeholder data.

**To add a county**, open the script and find `COUNTY_RESOURCE_SETS` near the top:
1. Copy one of the existing region blocks (e.g. `franklin: [...]`) and give it a new key, like `lorain: [...]`.
2. Fill in that county's actual crisis line, food bank, domestic violence hotline, and housing/legal aid — check each org's own site for current numbers.
3. In `COUNTY_TO_REGION` just below it, map the county name(s) to your new key: `'Lorain': 'lorain',`.
4. The county will now show up with a ✓ in the county dropdowns, and its resources will populate automatically for any client assigned to it.

Every number in the five seeded regions was checked against the organization's own site as of August 2026, but phone numbers and hours do drift — worth a periodic recheck, especially before a wider rollout.

## Updating an existing database
If you already ran `supabase-schema.sql` once and are adding the My Resources feature to a live database, run this in the SQL editor first:
```sql
alter table clients add column if not exists county text;

alter table workbook_progress drop constraint workbook_progress_track_check;
alter table workbook_progress add constraint workbook_progress_track_check
  check (track in ('sud','mh','comorbid','resources'));
```
