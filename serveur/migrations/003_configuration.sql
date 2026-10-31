-- 003 : configuration de l'établissement (étape 2 de l'onboarding).
--
-- Par organisation : années scolaires, niveaux, matières et coefficients.
-- Par site : classes. Frais : pour tout le groupe ou pour un site.
--
-- Droits : tous les membres lisent ; le fondateur configure l'organisation ;
-- un directeur gère les classes et les frais de son site.
-- Cohérence : des clés composées (id, organisation_id) empêchent de relier
-- une ligne à un site, une année ou un niveau d'une autre école.

alter table public.sites add constraint sites_id_organisation_unique unique (id, organisation_id);
alter table public.rattachements
  add constraint rattachements_site_meme_organisation
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade;

create table public.annees_scolaires (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  libelle text not null check (length(trim(libelle)) between 4 and 20),   -- « 2026-2027 »
  debut date not null,
  fin date not null check (fin > debut),
  en_cours boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id)
);
-- Une seule année en cours par organisation.
create unique index annees_une_en_cours on public.annees_scolaires (organisation_id) where en_cours;

create table public.niveaux (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  cycle text not null check (cycle in ('maternelle', 'primaire', 'college', 'lycee')),
  nom text not null check (length(trim(nom)) between 1 and 60),             -- « CP1 », « 7ème »
  ordre integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id)
);

create table public.classes (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid not null,
  annee_id uuid not null,
  niveau_id uuid not null,
  nom text not null check (length(trim(nom)) between 1 and 60),             -- « 7ème A »
  salle text,
  capacite integer check (capacite is null or capacite between 1 and 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade,
  foreign key (annee_id, organisation_id) references public.annees_scolaires (id, organisation_id) on delete cascade,
  foreign key (niveau_id, organisation_id) references public.niveaux (id, organisation_id) on delete cascade
);
create index classes_site_idx on public.classes (site_id);

create table public.matieres (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  niveau_id uuid not null,
  nom text not null check (length(trim(nom)) between 1 and 80),
  coefficient numeric(4, 1) not null default 1 check (coefficient > 0 and coefficient <= 20),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (niveau_id, organisation_id) references public.niveaux (id, organisation_id) on delete cascade
);

create table public.frais (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  annee_id uuid not null,
  site_id uuid,          -- vide = tous les sites
  niveau_id uuid,        -- vide = tous les niveaux
  libelle text not null check (length(trim(libelle)) between 2 and 80),     -- « Scolarité »
  montant_gnf bigint not null check (montant_gnf >= 0),
  periodicite text not null default 'unique' check (periodicite in ('unique', 'mensuel', 'trimestriel', 'annuel')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (annee_id, organisation_id) references public.annees_scolaires (id, organisation_id) on delete cascade,
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade,
  foreign key (niveau_id, organisation_id) references public.niveaux (id, organisation_id) on delete cascade
);

do $$
declare t text;
begin
  foreach t in array array['annees_scolaires', 'niveaux', 'classes', 'matieres', 'frais'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I
                    for each row execute function scolagrid.maj_updated_at()', t);
    execute format('create trigger organisation_immuable before update on public.%I
                    for each row execute function scolagrid.organisation_immuable()', t);
    execute format('create policy "membres lisent" on public.%I for select to authenticated
                    using (organisation_id in (select scolagrid.mes_organisations()))', t);
  end loop;

  -- Configuration de l'organisation : le fondateur.
  foreach t in array array['annees_scolaires', 'niveaux', 'matieres'] loop
    execute format('create policy "fondateur ajoute" on public.%I for insert to authenticated
                    with check (scolagrid.est_fondateur(organisation_id))', t);
    execute format('create policy "fondateur modifie" on public.%I for update to authenticated
                    using (scolagrid.est_fondateur(organisation_id)) with check (scolagrid.est_fondateur(organisation_id))', t);
    execute format('create policy "fondateur supprime" on public.%I for delete to authenticated
                    using (scolagrid.est_fondateur(organisation_id))', t);
  end loop;
end $$;

-- Classes : fondateur, ou directeur du site.
create policy "gestionnaire ajoute" on public.classes for insert to authenticated
  with check (scolagrid.gere_site(organisation_id, site_id));
create policy "gestionnaire modifie" on public.classes for update to authenticated
  using (scolagrid.gere_site(organisation_id, site_id)) with check (scolagrid.gere_site(organisation_id, site_id));
create policy "gestionnaire supprime" on public.classes for delete to authenticated
  using (scolagrid.gere_site(organisation_id, site_id));

-- Frais : pour tout le groupe, le fondateur ; pour un site, son gestionnaire.
create or replace function scolagrid.gere_frais(org uuid, site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when site is null then scolagrid.est_fondateur(org) else scolagrid.gere_site(org, site) end
$$;
revoke all on function scolagrid.gere_frais(uuid, uuid) from public;
grant execute on function scolagrid.gere_frais(uuid, uuid) to authenticated;

create policy "gestionnaire ajoute" on public.frais for insert to authenticated
  with check (scolagrid.gere_frais(organisation_id, site_id));
create policy "gestionnaire modifie" on public.frais for update to authenticated
  using (scolagrid.gere_frais(organisation_id, site_id)) with check (scolagrid.gere_frais(organisation_id, site_id));
create policy "gestionnaire supprime" on public.frais for delete to authenticated
  using (scolagrid.gere_frais(organisation_id, site_id));

alter publication powersync add table public.annees_scolaires, public.niveaux, public.classes, public.matieres, public.frais;
