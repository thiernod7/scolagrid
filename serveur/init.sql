-- Schéma Scolagrid. Rejouable sans risque à chaque installation.
-- Exécuté par installer.sh avec la variable psql :pw (mot de passe PowerSync).

-- Table de test « Hello ». Doit correspondre à app/lib/schema.dart.
create table if not exists public.hellos (
  id uuid primary key default gen_random_uuid(),
  message text not null,
  device text,
  created_at timestamptz not null default now()
);
alter table public.hellos owner to postgres;
alter table public.hellos replica identity full;

-- Sécurité : seuls les utilisateurs connectés lisent et écrivent.
alter table public.hellos enable row level security;
drop policy if exists "hello ouvert aux connectes" on public.hellos;
create policy "hello ouvert aux connectes" on public.hellos
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.hellos to authenticated;

-- Rôle dédié à PowerSync, qui lit les changements de la base.
do $$ begin
  if not exists (select from pg_roles where rolname = 'powersync_role') then
    create role powersync_role with replication bypassrls login;
  end if;
end $$;
alter role powersync_role with password :'pw';
grant select on all tables in schema public to powersync_role;
alter default privileges for role postgres in schema public grant select on tables to powersync_role;

-- Liste des tables que PowerSync synchronise.
do $$ begin
  if not exists (select from pg_publication where pubname = 'powersync') then
    create publication powersync for table public.hellos;
  end if;
end $$;
