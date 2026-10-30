-- À exécuter une fois dans Supabase : SQL Editor > New query > coller > Run.
-- Remplacer MOT_DE_PASSE_A_CHANGER par un mot de passe généré.

-- Table de test « Hello ». Doit correspondre au schéma dans app/lib/main.dart.
create table public.hellos (
  id uuid primary key default gen_random_uuid(),
  message text not null,
  device text,
  created_at timestamptz not null default now()
);
alter table public.hellos replica identity full;

-- Sécurité : seuls les utilisateurs connectés lisent et écrivent.
alter table public.hellos enable row level security;
create policy "hello ouvert aux connectes" on public.hellos
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.hellos to authenticated;

-- Rôle dédié à PowerSync, qui lit les changements de la base.
create role powersync_role with replication bypassrls login password 'MOT_DE_PASSE_A_CHANGER';
grant select on all tables in schema public to powersync_role;
alter default privileges in schema public grant select on tables to powersync_role;

-- Liste des tables que PowerSync synchronise.
create publication powersync for table public.hellos;
