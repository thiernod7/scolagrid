-- 018 : échéances. Délai de grâce, arrivée en cours d'année, échéancier aménagé.
--
-- * Délai de grâce : une échéance ne devient un arriéré que N jours après sa
--   date limite (7 par défaut). Réglé par le fondateur.
-- * Arrivée en cours d'année : l'école discute avec la famille. Trois choix,
--   notés sur l'inscription : année complète, à partir du mois d'arrivée
--   (calculé par l'application sur le calendrier), ou montant négocié
--   (somme retirée, avec motif, décidée par la direction).
-- * Échéancier aménagé : pour un élève, la direction peut changer les dates
--   ou découper une tranche (même total), avec un motif. Les autres élèves
--   gardent le calendrier de l'école.

alter table public.organisations
  add column delai_grace_jours integer not null default 7 check (delai_grace_jours between 0 and 60),
  add column arrivee_par_defaut text not null default 'mois' check (arrivee_par_defaut in ('complete', 'mois', 'negocie'));

alter table public.inscriptions
  add column arrivee_mode text check (arrivee_mode in ('complete', 'mois', 'negocie')),
  add column arrivee_retrait_gnf bigint check (arrivee_retrait_gnf is null or arrivee_retrait_gnf >= 0),
  add column arrivee_motif text check (arrivee_motif is null or length(trim(arrivee_motif)) between 3 and 200);

-- Un montant négocié : motif obligatoire, et seulement par la direction du site.
create or replace function scolagrid.arrivee_controlee() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.arrivee_mode = 'negocie' then
    if new.arrivee_retrait_gnf is null or new.arrivee_motif is null then
      raise exception 'Un montant négocié demande la somme retirée et un motif' using errcode = '23514';
    end if;
  else
    new.arrivee_retrait_gnf := null;
  end if;
  if new.arrivee_mode = 'negocie'
     and (tg_op = 'INSERT' or new.arrivee_mode is distinct from old.arrivee_mode
          or new.arrivee_retrait_gnf is distinct from old.arrivee_retrait_gnf)
     and current_user in ('authenticated', 'anon')
     and not scolagrid.gere_site(new.organisation_id, new.site_id) then
    raise exception 'Seule la direction peut accorder un montant négocié' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger inscription_arrivee before insert or update on public.inscriptions
  for each row execute function scolagrid.arrivee_controlee();

-- Échéancier aménagé d'un élève, frais par frais.
create table public.echeances_eleves (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  inscription_id uuid not null,
  frais_id uuid not null,
  ordre integer not null check (ordre between 1 and 36),
  libelle text not null check (length(trim(libelle)) between 1 and 40),
  montant_gnf bigint not null check (montant_gnf >= 0),
  date_limite date not null,
  motif text not null check (length(trim(motif)) between 3 and 200),
  par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (inscription_id, frais_id, ordre),
  foreign key (inscription_id, organisation_id) references public.inscriptions (id, organisation_id) on delete cascade,
  foreign key (frais_id, organisation_id) references public.frais (id, organisation_id) on delete cascade
);
create index echeances_eleves_inscription on public.echeances_eleves (inscription_id);

alter table public.echeances_eleves owner to postgres;
alter table public.echeances_eleves replica identity full;
alter table public.echeances_eleves enable row level security;
revoke all on public.echeances_eleves from anon, authenticated;
grant select on public.echeances_eleves to powersync_role;
grant select, insert, update, delete on public.echeances_eleves to authenticated;
create trigger maj_updated_at before update on public.echeances_eleves
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.echeances_eleves
  for each row execute function scolagrid.organisation_immuable();

create or replace function scolagrid.echeance_eleve_auteur() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then new.par := auth.uid(); end if;
  if tg_op = 'UPDATE' then
    new.inscription_id := old.inscription_id;
    new.frais_id := old.frais_id;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
create trigger echeance_eleve_auteur before insert or update on public.echeances_eleves
  for each row execute function scolagrid.echeance_eleve_auteur();

-- La direction du site de l'inscription aménage.
create or replace function scolagrid.amenage(ins uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select scolagrid.gere_site(i.organisation_id, i.site_id) from public.inscriptions i where i.id = ins), false)
$$;
revoke all on function scolagrid.amenage(uuid) from public;
grant execute on function scolagrid.amenage(uuid) to authenticated;

create policy "caisse : lecture" on public.echeances_eleves for select to authenticated
  using (scolagrid.voit_caisse(organisation_id));
create policy "direction : ajout" on public.echeances_eleves for insert to authenticated
  with check (scolagrid.amenage(inscription_id));
create policy "direction : modification" on public.echeances_eleves for update to authenticated
  using (scolagrid.amenage(inscription_id)) with check (scolagrid.amenage(inscription_id));
create policy "direction : retrait" on public.echeances_eleves for delete to authenticated
  using (scolagrid.amenage(inscription_id));

alter publication powersync add table public.echeances_eleves;
