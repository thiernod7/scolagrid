-- 019 : frais en grille.
--
-- * Calendrier de paiement de l'année, commun à toute l'école : tranches
--   (ou mois) avec leur date limite et leur part de la scolarité. Les
--   échéances de chaque niveau en découlent.
-- * Grille figée : dès qu'un paiement porte sur un frais, son montant ne
--   change plus qu'avec un motif ; chaque correction est gardée.
-- * Modes « sous réserve » réglables (chèque et virement par défaut).
-- * Le frais le plus précis l'emporte : celui d'un niveau (ou d'un site)
--   remplace, pour ce niveau, celui de « tous les niveaux » du même type.

alter table public.annees_scolaires
  add column periodicite text not null default 'tranches' check (periodicite in ('tranches', 'mensuelle', 'annuelle')),
  add column nb_mois integer not null default 9 check (nb_mois between 1 and 12);

alter table public.organisations
  add column modes_sous_reserve text not null default 'cheque,virement'
    check (modes_sous_reserve ~ '^((especes|cheque|virement|orange_money|mtn_money)(,(especes|cheque|virement|orange_money|mtn_money))*)?$');

alter table public.frais add column motif_correction text
  check (motif_correction is null or length(trim(motif_correction)) between 3 and 200);

-- Calendrier de paiement de l'année.
create table public.tranches_annee (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  annee_id uuid not null,
  ordre integer not null check (ordre between 1 and 24),
  libelle text not null check (length(trim(libelle)) between 1 and 40),
  date_limite date not null,
  part numeric(6, 3) not null check (part > 0 and part <= 100),   -- en % de la scolarité
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (annee_id, ordre),
  foreign key (annee_id, organisation_id) references public.annees_scolaires (id, organisation_id) on delete cascade
);
alter table public.tranches_annee owner to postgres;
alter table public.tranches_annee replica identity full;
alter table public.tranches_annee enable row level security;
revoke all on public.tranches_annee from anon, authenticated;
grant select on public.tranches_annee to powersync_role;
grant select, insert, update, delete on public.tranches_annee to authenticated;
create trigger maj_updated_at before update on public.tranches_annee
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.tranches_annee
  for each row execute function scolagrid.organisation_immuable();
create policy "membres lisent" on public.tranches_annee for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "fondateur ajoute" on public.tranches_annee for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur modifie" on public.tranches_annee for update to authenticated
  using (scolagrid.est_fondateur(organisation_id)) with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur supprime" on public.tranches_annee for delete to authenticated
  using (scolagrid.est_fondateur(organisation_id));
alter publication powersync add table public.tranches_annee;

-- Corrections d'un frais déjà payé : qui, quand, pourquoi.
create table public.historique_frais (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  frais_id uuid not null,
  ancien_gnf bigint not null,
  nouveau_gnf bigint not null,
  motif text not null,
  par uuid references auth.users (id) on delete set null,
  quand timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (frais_id, organisation_id) references public.frais (id, organisation_id) on delete cascade
);
alter table public.historique_frais owner to postgres;
alter table public.historique_frais replica identity full;
alter table public.historique_frais enable row level security;
revoke all on public.historique_frais from anon, authenticated;
grant select on public.historique_frais to powersync_role;
grant select on public.historique_frais to authenticated;
create policy "membres lisent" on public.historique_frais for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
alter publication powersync add table public.historique_frais;

create or replace function scolagrid.frais_fige() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.montant_gnf is distinct from old.montant_gnf
     and exists (select 1 from public.lignes_encaissement l where l.frais_id = old.id) then
    if new.motif_correction is null or new.motif_correction is not distinct from old.motif_correction then
      raise exception 'Ce frais a déjà été payé : sa correction demande un motif' using errcode = '23514';
    end if;
    insert into public.historique_frais (organisation_id, frais_id, ancien_gnf, nouveau_gnf, motif, par)
      values (old.organisation_id, old.id, old.montant_gnf, new.montant_gnf, new.motif_correction, auth.uid());
  end if;
  return new;
end $$;
create trigger frais_fige before update on public.frais
  for each row execute function scolagrid.frais_fige();

-- Modes « sous réserve » : lus dans les réglages de l'école.
create or replace function scolagrid.encaissement_protege() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated', 'anon') then
      new.encaisse_par := auth.uid();
      new.statut := 'valide';
      new.annule_par := null;
      new.annule_le := null;
      new.impressions := 0;
      new.confirmation := case when new.mode = any (string_to_array(
          (select o.modes_sous_reserve from public.organisations o where o.id = new.organisation_id), ','))
        then 'en_attente' else 'confirme' end;
    end if;
    return new;
  end if;
  new.site_id := old.site_id;
  new.annee_id := old.annee_id;
  new.numero := old.numero;
  new.carnet := old.carnet;
  new.feuille := old.feuille;
  new.payeur_nom := old.payeur_nom;
  new.payeur_contact_id := old.payeur_contact_id;
  new.mode := old.mode;
  new.reference := old.reference;
  new.date_effective := old.date_effective;
  new.total_gnf := old.total_gnf;
  new.poste_id := old.poste_id;
  new.encaisse_par := old.encaisse_par;
  new.created_at := old.created_at;
  new.impressions := greatest(old.impressions, new.impressions);
  if old.statut = 'annule' then
    new.statut := 'annule';
    new.motif_annulation := old.motif_annulation;
    new.annule_par := old.annule_par;
    new.annule_le := old.annule_le;
  elsif new.statut = 'annule' then
    if current_user in ('authenticated', 'anon') and not (
         scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu')
         or (old.encaisse_par = auth.uid() and old.created_at > now() - interval '24 hours')) then
      raise exception 'Annulation réservée à l''encaisseur (24 h) ou au titulaire du droit' using errcode = '42501';
    end if;
    new.annule_par := coalesce(auth.uid(), new.annule_par);
    new.annule_le := now();
  end if;
  if new.confirmation is distinct from old.confirmation and current_user in ('authenticated', 'anon')
     and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu') then
    new.confirmation := old.confirmation;
  end if;
  return new;
end $$;

-- Activation : le frais d'inscription le plus précis l'emporte.
create or replace function scolagrid.verifier_activation(ins uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  i public.inscriptions;
  niveau uuid;
  brut bigint := 0;
  du bigint := 0;
  f record;
  paye bigint;
  premier date;
begin
  select * into i from public.inscriptions where id = ins;
  if i.statut <> 'en_attente' then return; end if;
  select niveau_id into niveau from public.classes where id = i.classe_id;
  -- Le frais le plus précis l'emporte : celui du niveau (ou du site)
  -- remplace celui de « tous les niveaux » du même type.
  for f in
    with candidats as (
      select fr.type_frais, fr.montant_gnf,
             (case when fr.niveau_id is not null then 2 else 0 end) + (case when fr.site_id is not null then 1 else 0 end) as precision
      from public.frais fr
      where fr.annee_id = i.annee_id
        and fr.type_frais = case when i.type_admission = 'reinscription' then 'reinscription' else 'inscription' end
        and (fr.site_id is null or fr.site_id = i.site_id)
        and (fr.niveau_id is null or fr.niveau_id = niveau))
    select c.type_frais, c.montant_gnf from candidats c where c.precision = (select max(precision) from candidats)
  loop
    brut := brut + f.montant_gnf;
    du := du + f.montant_gnf - scolagrid.reduction_frais(ins, f.type_frais, f.montant_gnf);
  end loop;
  select coalesce(sum(l.montant_gnf) filter (where fr.type_frais in ('inscription', 'reinscription')), 0),
         min(e.date_effective)
    into paye, premier
  from public.lignes_encaissement l
  join public.encaissements e on e.id = l.encaissement_id and e.statut = 'valide' and e.confirmation <> 'rejete'
  join public.frais fr on fr.id = l.frais_id
  where l.inscription_id = ins;
  if (premier is not null and paye >= du) or (brut > 0 and du = 0) then
    update public.inscriptions set statut = 'actif', date_actif = coalesce(premier, current_date) where id = ins;
  end if;
end $$;
