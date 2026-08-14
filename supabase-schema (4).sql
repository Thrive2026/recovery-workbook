-- =========================================================================
-- Recovery Workbook — Supabase schema (v2: client logins + scoped access)
-- Run this once in the SQL editor of the Supabase project you plan to use.
-- If you're upgrading from the v1 schema, see "UPGRADING FROM V1" at the
-- bottom instead of running this whole file fresh.
-- =========================================================================

-- 1. PROVIDERS ---------------------------------------------------------------
-- One row per staff member who logs in. Created automatically the first
-- time they sign in (see app code), but you can also add rows by hand.
create table if not exists providers (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text,
  created_at timestamptz not null default now()
);

alter table providers enable row level security;

drop policy if exists "providers_select_all" on providers;
create policy "providers_select_all" on providers
  for select using (auth.role() = 'authenticated');

drop policy if exists "providers_upsert_own" on providers;
create policy "providers_upsert_own" on providers
  for insert with check (auth.uid() = id);

drop policy if exists "providers_update_own" on providers;
create policy "providers_update_own" on providers
  for update using (auth.uid() = id);


-- 2. CLIENTS ------------------------------------------------------------------
create table if not exists clients (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  county text,
  archived boolean not null default false,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table clients enable row level security;


-- 3. CLIENT LOGINS -------------------------------------------------------------
-- Maps one auth.users account to exactly one client record. When a client
-- signs in, the app looks them up here (instead of in `providers`) and shows
-- them only their own record. Created by a provider from the client's page.
create table if not exists client_logins (
  id uuid primary key references auth.users(id) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  email text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (client_id)
);


-- 4. CLIENT PROVIDER ACCESS -----------------------------------------------------
-- Which providers (by email) can see a given client. The provider who
-- creates a client is granted access automatically (see app code); this
-- table is for *additional* providers sharing the case.
create table if not exists client_provider_access (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id) on delete cascade,
  provider_email text not null,
  added_by uuid references auth.users(id),
  added_at timestamptz not null default now(),
  unique (client_id, provider_email)
);


-- 5. ACCESS CHECK FUNCTION -------------------------------------------------------
-- Central place that answers "can the currently signed-in user see this
-- client?" Used by every RLS policy below so the rule only lives in one
-- place. Runs as the function owner (SECURITY DEFINER) so it can read the
-- three tables above regardless of their own RLS — this is the standard,
-- safe way to avoid circular RLS. Do NOT enable "Force RLS" on these tables,
-- or this function stops working.
create or replace function has_client_access(cid uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from clients c
    where c.id = cid
      and (
        c.created_by = auth.uid()
        or exists (
          select 1 from client_provider_access cpa
          where cpa.client_id = c.id
            and lower(cpa.provider_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        )
        or exists (
          select 1 from client_logins cl
          where cl.id = auth.uid() and cl.client_id = c.id
        )
      )
  );
$$;

-- Same pattern as has_client_access() above, wrapping a raw cross-table
-- check in SECURITY DEFINER. Without this, a plain inline
-- "exists (select 1 from providers p where p.id = auth.uid())" inside a
-- WITH CHECK clause can fail unpredictably on INSERT even when the
-- underlying data is correct — SECURITY DEFINER sidesteps it the same way
-- it does for has_client_access().
create or replace function is_registered_provider()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from providers p where p.id = auth.uid());
$$;

-- Clients: visible/editable only to providers with access, or the client
-- themselves. Only providers (not clients) may create new client records.
drop policy if exists "clients_all_authenticated" on clients;
drop policy if exists "clients_select_scoped" on clients;
create policy "clients_select_scoped" on clients
  for select using (has_client_access(id));

drop policy if exists "clients_update_scoped" on clients;
create policy "clients_update_scoped" on clients
  for update using (has_client_access(id));

drop policy if exists "clients_insert_providers_only" on clients;
create policy "clients_insert_providers_only" on clients
  for insert with check (is_registered_provider());

alter table client_logins enable row level security;
drop policy if exists "client_logins_select_scoped" on client_logins;
create policy "client_logins_select_scoped" on client_logins
  for select using (has_client_access(client_id));

drop policy if exists "client_logins_insert_providers" on client_logins;
create policy "client_logins_insert_providers" on client_logins
  for insert with check (
    has_client_access(client_id)
    and is_registered_provider()
  );

drop policy if exists "client_logins_delete_providers" on client_logins;
create policy "client_logins_delete_providers" on client_logins
  for delete using (
    has_client_access(client_id)
    and is_registered_provider()
  );

alter table client_provider_access enable row level security;
drop policy if exists "cpa_select_scoped" on client_provider_access;
create policy "cpa_select_scoped" on client_provider_access
  for select using (has_client_access(client_id));

drop policy if exists "cpa_insert_scoped" on client_provider_access;
create policy "cpa_insert_scoped" on client_provider_access
  for insert with check (
    has_client_access(client_id)
    and is_registered_provider()
  );

drop policy if exists "cpa_delete_scoped" on client_provider_access;
create policy "cpa_delete_scoped" on client_provider_access
  for delete using (
    has_client_access(client_id)
    and is_registered_provider()
  );


-- 6. WORKBOOK PROGRESS ---------------------------------------------------------
-- One row per client per track (sud / mh / comorbid / resources / careteam).
create table if not exists workbook_progress (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id) on delete cascade,
  track text not null check (track in ('sud','mh','comorbid','resources','careteam')),
  data jsonb not null default '{}'::jsonb,
  total_prompts integer not null default 0,
  completed_prompts integer not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  unique (client_id, track)
);

create index if not exists idx_workbook_progress_client on workbook_progress(client_id);

alter table workbook_progress enable row level security;

drop policy if exists "workbook_progress_all_authenticated" on workbook_progress;
drop policy if exists "workbook_progress_scoped" on workbook_progress;
create policy "workbook_progress_scoped" on workbook_progress
  for all using (has_client_access(client_id)) with check (has_client_access(client_id));


-- 6b. WRITE FUNCTIONS ----------------------------------------------------------
-- Every write from the app goes through one of these SECURITY DEFINER
-- functions instead of a raw table insert/upsert. This was added after
-- extensive debugging turned up a case where a direct authenticated INSERT
-- into `clients` was rejected by Postgres's RLS enforcement even with the
-- policy set to `with check (true)` — confirmed, via many independent
-- checks, not caused by the policy, grants, or data. Routing writes through
-- a SECURITY DEFINER function (which performs its own explicit permission
-- check in the function body, then writes as the function owner) sidesteps
-- that issue reliably. If a future Supabase/Postgres update resolves the
-- underlying cause, these functions are still safe to keep — they're not a
-- hack, just an extra explicit layer.
create or replace function create_client(p_full_name text, p_county text default null)
returns clients
language plpgsql
security definer
set search_path = public
as $$
declare
  new_row clients;
begin
  if not is_registered_provider() then
    raise exception 'Only registered providers can add clients';
  end if;

  insert into clients (full_name, county, created_by)
  values (p_full_name, p_county, auth.uid())
  returning * into new_row;

  return new_row;
end;
$$;

create or replace function save_workbook_progress(
  p_client_id uuid, p_track text, p_data jsonb, p_total int, p_completed int
)
returns workbook_progress
language plpgsql
security definer
set search_path = public
as $$
declare
  row_out workbook_progress;
begin
  if not has_client_access(p_client_id) then
    raise exception 'No access to this client';
  end if;

  insert into workbook_progress (client_id, track, data, total_prompts, completed_prompts, updated_at, updated_by)
  values (p_client_id, p_track, p_data, p_total, p_completed, now(), auth.uid())
  on conflict (client_id, track) do update
    set data = excluded.data,
        total_prompts = excluded.total_prompts,
        completed_prompts = excluded.completed_prompts,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by
  returning * into row_out;

  return row_out;
end;
$$;

create or replace function create_client_login(p_login_id uuid, p_client_id uuid, p_email text)
returns client_logins
language plpgsql
security definer
set search_path = public
as $$
declare
  row_out client_logins;
begin
  if not (has_client_access(p_client_id) and is_registered_provider()) then
    raise exception 'Not permitted to create a login for this client';
  end if;

  insert into client_logins (id, client_id, email, created_by)
  values (p_login_id, p_client_id, p_email, auth.uid())
  returning * into row_out;

  return row_out;
end;
$$;

create or replace function add_provider_access(p_client_id uuid, p_email text)
returns client_provider_access
language plpgsql
security definer
set search_path = public
as $$
declare
  row_out client_provider_access;
begin
  if not (has_client_access(p_client_id) and is_registered_provider()) then
    raise exception 'Not permitted to add access for this client';
  end if;

  insert into client_provider_access (client_id, provider_email, added_by)
  values (p_client_id, p_email, auth.uid())
  returning * into row_out;

  return row_out;
end;
$$;


-- 7. GRANTS -------------------------------------------------------------------
-- RLS policies above control WHICH rows a role can touch, but Postgres also
-- needs a baseline grant saying the role can touch the table AT ALL. If your
-- project has "Automatically expose new tables" turned OFF in Database →
-- API Settings (Supabase's own recommended default, and what these setup
-- instructions tell you to pick), tables created via the SQL Editor do NOT
-- get that baseline grant automatically — every query fails with
-- "permission denied for table X" even though RLS is set up correctly.
-- This section grants the baseline access; RLS still does the real
-- row-level restriction on top of it. Safe to re-run.
grant usage on schema public to authenticated;

grant select, insert, update, delete on public.providers to authenticated;
grant select, insert, update, delete on public.clients to authenticated;
grant select, insert, update, delete on public.client_logins to authenticated;
grant select, insert, update, delete on public.client_provider_access to authenticated;
grant select, insert, update, delete on public.workbook_progress to authenticated;

grant execute on function public.has_client_access(uuid) to authenticated;
grant execute on function public.is_registered_provider() to authenticated;
grant execute on function public.create_client(text, text) to authenticated;
grant execute on function public.save_workbook_progress(uuid, text, jsonb, int, int) to authenticated;
grant execute on function public.create_client_login(uuid, uuid, text) to authenticated;
grant execute on function public.add_provider_access(uuid, text) to authenticated;


-- =========================================================================
-- Creating provider (staff) logins
-- =========================================================================
-- Add each provider from Supabase Dashboard → Authentication → Users →
-- "Add user". Use their Thrive email and a temporary password, and have
-- them change it on first login (or send a password-reset link).
-- The app creates their `providers` row automatically the first time they
-- sign in — client accounts (created from inside the app) never get a
-- `providers` row, which is how the app tells the two roles apart.


-- =========================================================================
-- UPGRADING FROM V1
-- =========================================================================
-- If you already ran the earlier version of this schema, run this instead
-- of the whole file above:
/*
alter table clients add column if not exists county text;

alter table workbook_progress drop constraint if exists workbook_progress_track_check;
alter table workbook_progress add constraint workbook_progress_track_check
  check (track in ('sud','mh','comorbid','resources','careteam'));

alter table providers add column if not exists email text;

create table if not exists client_logins (
  id uuid primary key references auth.users(id) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  email text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (client_id)
);

create table if not exists client_provider_access (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id) on delete cascade,
  provider_email text not null,
  added_by uuid references auth.users(id),
  added_at timestamptz not null default now(),
  unique (client_id, provider_email)
);

create or replace function has_client_access(cid uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from clients c
    where c.id = cid
      and (
        c.created_by = auth.uid()
        or exists (select 1 from client_provider_access cpa where cpa.client_id = c.id and lower(cpa.provider_email) = lower(coalesce(auth.jwt() ->> 'email','')))
        or exists (select 1 from client_logins cl where cl.id = auth.uid() and cl.client_id = c.id)
      )
  );
$$;

create or replace function is_registered_provider()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from providers p where p.id = auth.uid());
$$;

drop policy if exists "clients_all_authenticated" on clients;
create policy "clients_select_scoped" on clients for select using (has_client_access(id));
create policy "clients_update_scoped" on clients for update using (has_client_access(id));
create policy "clients_insert_providers_only" on clients for insert with check (is_registered_provider());

alter table client_logins enable row level security;
create policy "client_logins_select_scoped" on client_logins for select using (has_client_access(client_id));
create policy "client_logins_insert_providers" on client_logins for insert with check (has_client_access(client_id) and is_registered_provider());
create policy "client_logins_delete_providers" on client_logins for delete using (has_client_access(client_id) and is_registered_provider());

alter table client_provider_access enable row level security;
create policy "cpa_select_scoped" on client_provider_access for select using (has_client_access(client_id));
create policy "cpa_insert_scoped" on client_provider_access for insert with check (has_client_access(client_id) and is_registered_provider());
create policy "cpa_delete_scoped" on client_provider_access for delete using (has_client_access(client_id) and is_registered_provider());

drop policy if exists "workbook_progress_all_authenticated" on workbook_progress;
create policy "workbook_progress_scoped" on workbook_progress for all using (has_client_access(client_id)) with check (has_client_access(client_id));

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.providers to authenticated;
grant select, insert, update, delete on public.clients to authenticated;
grant select, insert, update, delete on public.client_logins to authenticated;
grant select, insert, update, delete on public.client_provider_access to authenticated;
grant select, insert, update, delete on public.workbook_progress to authenticated;
grant execute on function is_registered_provider() to authenticated;
grant execute on function public.has_client_access(uuid) to authenticated;
*/
