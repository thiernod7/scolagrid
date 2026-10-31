-- 012 : clôture de caisse journalière.
--
-- Chaque encaisseur clôture sa caisse de la journée, par site : le système
-- calcule les espèces attendues, l'encaisseur saisit ce qu'il a compté, l'écart
-- doit être justifié s'il n'est pas nul. Une journée close ne se modifie plus :
-- annuler un de ses reçus demande le droit « annuler_recu ».
-- Hors ligne d'abord : un reçu qui arrive après la clôture de son jour (poste
-- resté sans réseau) n'est jamais refusé — l'argent ne doit pas disparaître —
-- mais il est marqué « après clôture » pour que l'école le voie.

create table public.clotures_caisse (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid not null,
  encaisse_par uuid not null references auth.users (id),
  jour date not null,
  attendu_especes bigint not null default 0,
  compte_especes bigint not null check (compte_especes >= 0),
  ecart bigint not null default 0,
  justification text check (justification is null or length(trim(justification)) between 3 and 500),
  nb_recus integer not null default 0,
  total_autres_modes bigint not null default 0,
  poste_id uuid references public.postes (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, site_id, encaisse_par, jour),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id)
);

alter table public.encaissements add column apres_cloture boolean not null default false;

alter table public.clotures_caisse owner to postgres;
alter table public.clotures_caisse replica identity full;
alter table public.clotures_caisse enable row level security;
revoke all on public.clotures_caisse from anon, authenticated;
grant select on public.clotures_caisse to powersync_role;

-- Le serveur recalcule l'attendu à partir des reçus qu'il a reçus ; l'écart
-- non nul exige une justification. Une clôture ne se modifie pas.
create or replace function scolagrid.cloture_calculee() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'Une clôture de caisse ne se modifie pas' using errcode = '42501';
  end if;
  select coalesce(sum(total_gnf) filter (where mode = 'especes'), 0),
         count(*),
         coalesce(sum(total_gnf) filter (where mode <> 'especes'), 0)
    into new.attendu_especes, new.nb_recus, new.total_autres_modes
  from public.encaissements
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and date_effective = new.jour and statut = 'valide';
  new.ecart := new.compte_especes - new.attendu_especes;
  if new.ecart <> 0 and new.justification is null then
    raise exception 'Un écart de caisse doit être justifié' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger cloture_calculee before insert or update on public.clotures_caisse
  for each row execute function scolagrid.cloture_calculee();
revoke all on function scolagrid.cloture_calculee() from public;

-- Un reçu daté d'un jour déjà clôturé est accepté, mais signalé.
create or replace function scolagrid.marquer_apres_cloture() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.apres_cloture := exists (
    select 1 from public.clotures_caisse c
    where c.organisation_id = new.organisation_id and c.site_id = new.site_id
      and c.encaisse_par = new.encaisse_par and c.jour = new.date_effective);
  return new;
end $$;
-- Après encaissement_protege (qui fixe encaisse_par) : ordre alphabétique des déclencheurs.
create trigger encaissement_z_apres_cloture before insert on public.encaissements
  for each row execute function scolagrid.marquer_apres_cloture();
revoke all on function scolagrid.marquer_apres_cloture() from public;

-- Annuler un reçu d'une journée close : seulement avec le droit « annuler_recu ».
create or replace function scolagrid.annulation_journee_close() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.statut = 'annule' and old.statut = 'valide'
     and nullif(current_setting('request.jwt.claim.sub', true), '') is not null
     and exists (select 1 from public.clotures_caisse c
                 where c.organisation_id = old.organisation_id and c.site_id = old.site_id
                   and c.encaisse_par = old.encaisse_par and c.jour = old.date_effective)
     and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu') then
    raise exception 'Journée clôturée : l''annulation demande le droit « annuler un reçu »' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger encaissement_journee_close before update on public.encaissements
  for each row execute function scolagrid.annulation_journee_close();
revoke all on function scolagrid.annulation_journee_close() from public;

-- Règles d'accès : chacun clôture sa propre caisse ; la direction et la caisse lisent.
grant select, insert on public.clotures_caisse to authenticated;
create policy "caisse : lecture" on public.clotures_caisse for select to authenticated
  using (scolagrid.voit_caisse(organisation_id));
create policy "caisse : clôture de sa caisse" on public.clotures_caisse for insert to authenticated
  with check (encaisse_par = auth.uid() and scolagrid.a_le_droit(organisation_id, site_id, 'encaisser'));

alter publication powersync add table public.clotures_caisse;
