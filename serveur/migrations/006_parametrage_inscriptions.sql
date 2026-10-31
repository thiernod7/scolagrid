-- 006 : paramétrage nécessaire aux inscriptions et aux encaissements.
--
-- Identité de l'école (pour les documents) et codes figés qui entrent dans les
-- numéros : sigle de l'école et code du site, ex. ALPHA-DONKA-2026-B042.
-- Frais typés (inscription, réinscription, scolarité, optionnel) et échéances
-- de la scolarité (tranches ou mois), qui servent à l'échéancier des élèves.

-- Identité de l'école ----------------------------------------------------------

alter table public.organisations
  add column code text check (code is null or code ~ '^[A-Z0-9]{2,10}$'),
  add column nom_officiel text check (nom_officiel is null or length(trim(nom_officiel)) between 2 and 160),
  add column slogan text check (slogan is null or length(slogan) <= 120),
  add column quartier text check (quartier is null or length(quartier) <= 80),
  add column telephone text check (telephone is null or telephone ~ '^\+?[0-9 ]{8,20}$'),
  add column email text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column responsable_nom text check (responsable_nom is null or length(trim(responsable_nom)) between 2 and 120),
  add column responsable_titre text check (responsable_titre is null or length(trim(responsable_titre)) between 2 and 60);
-- Le sigle est unique sur tout Scolagrid : les matricules le sont aussi.
create unique index organisations_code_unique on public.organisations (code) where code is not null;

alter table public.sites
  add column code text check (code is null or code ~ '^[A-Z0-9]{2,10}$'),
  add column quartier text check (quartier is null or length(quartier) <= 80),
  add column telephone text check (telephone is null or telephone ~ '^\+?[0-9 ]{8,20}$');
create unique index sites_code_unique on public.sites (organisation_id, code) where code is not null;

-- Une fois choisis, le sigle et le code du site ne changent plus : ils sont
-- imprimés dans les matricules et les numéros de reçu.
create or replace function scolagrid.code_fige() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.code is not null and new.code is distinct from old.code then
    raise exception 'Le code ne peut plus être modifié : il figure dans les matricules' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger code_fige before update on public.organisations
  for each row execute function scolagrid.code_fige();
create trigger code_fige before update on public.sites
  for each row execute function scolagrid.code_fige();

-- Frais typés -------------------------------------------------------------------

alter table public.frais
  add column type_frais text not null default 'optionnel'
    check (type_frais in ('inscription', 'reinscription', 'scolarite', 'optionnel')),
  add constraint frais_id_organisation_unique unique (id, organisation_id);
alter table public.frais drop constraint frais_periodicite_check;
alter table public.frais add constraint frais_periodicite_check
  check (periodicite in ('unique', 'mensuel', 'trimestriel', 'annuel', 'tranches'));

-- Reprise : on devine le type des frais déjà saisis d'après leur libellé.
update public.frais set type_frais = case
  when libelle ilike 'r_inscription%' or libelle ilike 'réinscription%' then 'reinscription'
  when libelle ilike 'inscription%' then 'inscription'
  when libelle ilike 'scolarit%' or libelle ilike 'mensualit%' then 'scolarite'
  else 'optionnel' end;

-- Échéances d'un frais (tranches ou mois). Le montant du frais est le total de
-- l'année ; les échéances le répartissent, dans l'ordre où elles se paient.
create table public.echeances (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  frais_id uuid not null,
  ordre integer not null check (ordre between 1 and 24),
  libelle text not null check (length(trim(libelle)) between 1 and 40),     -- « Tranche 1 », « Novembre »
  montant_gnf bigint not null check (montant_gnf >= 0),
  date_limite date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (frais_id, ordre),
  foreign key (frais_id, organisation_id) references public.frais (id, organisation_id) on delete cascade
);

alter table public.echeances owner to postgres;
alter table public.echeances replica identity full;
alter table public.echeances enable row level security;
revoke all on public.echeances from anon, authenticated;
grant select on public.echeances to powersync_role;
grant select, insert, update, delete on public.echeances to authenticated;
create trigger maj_updated_at before update on public.echeances
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.echeances
  for each row execute function scolagrid.organisation_immuable();

-- Les échéances suivent les droits du frais : fondateur pour tout le groupe,
-- gestionnaire du site pour les frais d'un site.
create or replace function scolagrid.gere_echeances(frais uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select scolagrid.gere_frais(f.organisation_id, f.site_id) from public.frais f where f.id = frais), false)
$$;
revoke all on function scolagrid.gere_echeances(uuid) from public;
grant execute on function scolagrid.gere_echeances(uuid) to authenticated;

create policy "membres lisent" on public.echeances for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "gestionnaire ajoute" on public.echeances for insert to authenticated
  with check (scolagrid.gere_echeances(frais_id));
create policy "gestionnaire modifie" on public.echeances for update to authenticated
  using (scolagrid.gere_echeances(frais_id)) with check (scolagrid.gere_echeances(frais_id));
create policy "gestionnaire supprime" on public.echeances for delete to authenticated
  using (scolagrid.gere_echeances(frais_id));

alter publication powersync add table public.echeances;
