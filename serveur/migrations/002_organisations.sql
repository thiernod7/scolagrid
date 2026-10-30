-- 002 : organisations, sites, rattachements et personnes.
--
-- Organisation = un client (groupe scolaire). Site = une école physique.
-- Rattachement = (personne, organisation, site ou tous les sites, rôle) :
-- c'est lui qui donne les droits. Personne = profil visible des collègues.
--
-- Sécurité : toutes les tables ont des règles RLS. Les fonctions d'aide
-- vivent dans le schéma scolagrid, qui n'est pas exposé par l'API.

-- Horodatage et protections communes ---------------------------------------

create or replace function scolagrid.maj_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- organisation_id ne change jamais : une ligne ne passe pas d'un client à un autre.
create or replace function scolagrid.organisation_immuable() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.organisation_id is distinct from old.organisation_id then
    raise exception 'organisation_id ne peut pas être modifié' using errcode = '42501';
  end if;
  return new;
end $$;

-- Tables --------------------------------------------------------------------

create table public.organisations (
  id uuid primary key default gen_random_uuid(),
  nom text not null check (length(trim(nom)) between 2 and 120),
  ville text not null check (length(trim(ville)) between 2 and 80),
  -- en_attente : créée, pas encore activée par Scolagrid ; active ; suspendue.
  statut text not null default 'en_attente' check (statut in ('en_attente', 'active', 'suspendue')),
  cree_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.sites (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  nom text not null check (length(trim(nom)) between 2 and 120),
  ville text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index sites_organisation_idx on public.sites (organisation_id);

create table public.rattachements (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid references public.sites (id) on delete cascade, -- vide = tous les sites
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('fondateur', 'directeur', 'secretaire', 'enseignant')),
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (organisation_id, site_id, user_id, role)
);
create index rattachements_user_idx on public.rattachements (user_id);
create index rattachements_organisation_idx on public.rattachements (organisation_id);

create table public.personnes (
  id uuid primary key references auth.users (id) on delete cascade,
  nom_complet text not null check (length(trim(nom_complet)) between 2 and 120),
  telephone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['organisations', 'sites', 'rattachements', 'personnes'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I
                    for each row execute function scolagrid.maj_updated_at()', t);
  end loop;
end $$;

create trigger organisation_immuable before update on public.sites
  for each row execute function scolagrid.organisation_immuable();
create trigger organisation_immuable before update on public.rattachements
  for each row execute function scolagrid.organisation_immuable();

-- Le statut et le créateur d'une organisation ne se changent pas depuis l'app.
create or replace function scolagrid.organisation_protegee() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.statut := old.statut;
    new.cree_par := old.cree_par;
  end if;
  return new;
end $$;
create trigger organisation_protegee before update on public.organisations
  for each row execute function scolagrid.organisation_protegee();

-- Fonctions d'aide aux règles (security definer : elles lisent les
-- rattachements sans repasser par les règles, ce qui évite les boucles).

grant usage on schema scolagrid to authenticated;

create or replace function scolagrid.mes_organisations() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select organisation_id from public.rattachements where user_id = auth.uid() and actif
$$;

create or replace function scolagrid.est_fondateur(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where user_id = auth.uid() and actif and organisation_id = org and role = 'fondateur')
$$;

-- Fondateur de l'organisation, ou directeur de ce site (ou de tous les sites).
create or replace function scolagrid.gere_site(org uuid, site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where user_id = auth.uid() and actif and organisation_id = org
                   and (role = 'fondateur' or (role = 'directeur' and (site_id is null or site_id = site))))
$$;

create or replace function scolagrid.mes_collegues() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct r.user_id from public.rattachements r
  where r.organisation_id in (select organisation_id from public.rattachements where user_id = auth.uid() and actif)
$$;

revoke all on function scolagrid.mes_organisations(), scolagrid.est_fondateur(uuid),
  scolagrid.gere_site(uuid, uuid), scolagrid.mes_collegues() from public;
grant execute on function scolagrid.mes_organisations(), scolagrid.est_fondateur(uuid),
  scolagrid.gere_site(uuid, uuid), scolagrid.mes_collegues() to authenticated;

-- Règles d'accès ------------------------------------------------------------

grant select, update on public.organisations to authenticated;
create policy "membres lisent" on public.organisations for select to authenticated
  using (id in (select scolagrid.mes_organisations()));
create policy "fondateur modifie" on public.organisations for update to authenticated
  using (scolagrid.est_fondateur(id)) with check (scolagrid.est_fondateur(id));

grant select, insert, update on public.sites to authenticated;
create policy "membres lisent" on public.sites for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "fondateur ajoute" on public.sites for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id));
create policy "gestionnaire modifie" on public.sites for update to authenticated
  using (scolagrid.gere_site(organisation_id, id)) with check (scolagrid.gere_site(organisation_id, id));

-- Les rattachements se créent par les fonctions du serveur (création d'espace,
-- puis invitations à l'étape 3), jamais directement depuis l'app.
grant select on public.rattachements to authenticated;
create policy "chacun voit les siens, les gestionnaires ceux de leur périmètre" on public.rattachements
  for select to authenticated
  using (user_id = auth.uid()
         or scolagrid.est_fondateur(organisation_id)
         or (site_id is not null and scolagrid.gere_site(organisation_id, site_id)));

grant select, insert, update on public.personnes to authenticated;
create policy "collègues lisent" on public.personnes for select to authenticated
  using (id = auth.uid() or id in (select scolagrid.mes_collegues()));
create policy "chacun crée son profil" on public.personnes for insert to authenticated
  with check (id = auth.uid());
create policy "chacun modifie son profil" on public.personnes for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Étape 1 de l'onboarding : créer l'espace d'une école -----------------------

create or replace function public.creer_espace_ecole(
  nom_groupe text, ville text, nom_site text, nom_complet text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  org uuid;
begin
  -- Les informations du jeton de connexion, telles que l'API les transmet.
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  if (select count(*) from public.organisations where cree_par = moi) >= 5 then
    raise exception 'Trop d''espaces créés avec ce compte' using errcode = '54000';
  end if;

  insert into public.personnes (id, nom_complet, telephone)
  values (moi, trim(nom_complet), (select phone from auth.users where id = moi))
  on conflict (id) do update set nom_complet = excluded.nom_complet;

  insert into public.organisations (nom, ville, cree_par)
  values (trim(nom_groupe), trim(ville), moi)
  returning id into org;

  insert into public.sites (organisation_id, nom, ville)
  values (org, trim(nom_site), trim(ville));

  insert into public.rattachements (organisation_id, site_id, user_id, role)
  values (org, null, moi, 'fondateur');

  return org;
end $$;

revoke all on function public.creer_espace_ecole(text, text, text, text) from public, anon;
grant execute on function public.creer_espace_ecole(text, text, text, text) to authenticated;

-- Synchronisation : PowerSync suit aussi ces tables.
alter publication powersync add table public.organisations, public.sites, public.rattachements, public.personnes;
