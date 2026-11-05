-- 035 : jour de caisse et dates sûres.
--
-- Un reçu porte deux dates :
--   - la DATE EFFECTIVE : le jour où le parent a payé (choisie par le comptable),
--     imprimée sur le reçu et utilisée pour l'échéancier ;
--   - le JOUR DE CAISSE : le jour où l'argent est enregistré à la caisse. C'est
--     lui qui range le reçu dans le journal et dans la clôture : un paiement du 3
--     saisi le 5 entre dans la caisse du 5 (« payé le 03/11 »), et une journée
--     clôturée ne bouge plus.
-- Dépenses (sortie_le) et remboursements (verse_le) avaient déjà leur jour de caisse.
--
-- Horloge des postes : le serveur garde l'heure où il a REÇU chaque opération, et
-- ramène à aujourd'hui un jour de caisse daté dans le futur (horloge de
-- l'ordinateur en avance), en le signalant. Rien n'est refusé : l'argent ne doit
-- pas disparaître. La direction peut corriger la date d'un reçu mal daté.

-- L'heure du serveur : l'app compare l'horloge du poste à celle-ci.
create or replace function public.heure_serveur() returns timestamptz
language sql stable set search_path = '' as $$ select now() $$;
revoke all on function public.heure_serveur() from public;
grant execute on function public.heure_serveur() to anon, authenticated;

alter table public.encaissements
  add column jour_caisse date,
  add column recu_serveur_le timestamptz,
  add column date_douteuse boolean not null default false,
  add column date_initiale date,                -- avant une correction de date
  add column motif_correction_date text check (motif_correction_date is null or length(trim(motif_correction_date)) between 3 and 300),
  add column date_corrigee_par uuid references auth.users (id) on delete set null,
  add column date_corrigee_le timestamptz;
alter table public.remboursements add column recu_serveur_le timestamptz;
alter table public.depenses add column recu_serveur_le timestamptz;

-- Les reçus existants restent dans leur journée (les clôtures faites restent justes).
alter table public.encaissements disable trigger user;
update public.encaissements set jour_caisse = date_effective, recu_serveur_le = created_at;
alter table public.encaissements enable trigger user;
-- Pas de valeur par défaut : un poste pas encore à jour n'envoie pas le jour de caisse,
-- on garde alors sa date effective (comme avant).
alter table public.encaissements alter column jour_caisse set not null;
create index encaissements_caisse_idx on public.encaissements (organisation_id, jour_caisse);

-- Dates d'un reçu à son arrivée sur le serveur.
create or replace function scolagrid.encaissement_dates() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.recu_serveur_le := now();
    new.date_initiale := null; new.motif_correction_date := null;
    new.date_corrigee_par := null; new.date_corrigee_le := null;
    new.jour_caisse := coalesce(new.jour_caisse, least(new.date_effective, current_date), current_date);
    new.date_douteuse := false;
    -- Horloge du poste en avance : on ne range pas l'argent dans une journée à venir.
    if new.jour_caisse > current_date then
      new.jour_caisse := current_date;
      new.date_douteuse := true;
    end if;
    if new.date_effective > current_date then
      new.date_douteuse := true;
    end if;
    return new;
  end if;
  new.recu_serveur_le := old.recu_serveur_le;
  new.date_douteuse := old.date_douteuse;
  -- Correction de la date (direction) : date effective et jour de caisse ensemble.
  -- Une correction se reconnaît à son motif ; sans lui, les dates restent figées (comme avant).
  if (new.date_effective is distinct from old.date_effective or new.jour_caisse is distinct from old.jour_caisse)
     and new.motif_correction_date is distinct from old.motif_correction_date then
    if current_user in ('authenticated', 'anon')
       and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu') then
      raise exception 'Corriger la date d''un reçu demande le droit « annuler un reçu »' using errcode = '42501';
    end if;
    if old.statut <> 'valide' then
      raise exception 'Un reçu annulé ne se corrige pas' using errcode = '23514';
    end if;
    if new.date_effective > current_date or new.jour_caisse > current_date then
      raise exception 'Une date dans le futur n''est pas possible' using errcode = '23514';
    end if;
    if new.date_effective > new.jour_caisse then
      raise exception 'Le parent ne peut pas avoir payé après l''enregistrement' using errcode = '23514';
    end if;
    if exists (select 1 from public.clotures_caisse c
               where c.organisation_id = old.organisation_id and c.site_id = old.site_id
                 and c.encaisse_par = old.encaisse_par and c.jour in (old.jour_caisse, new.jour_caisse)) then
      raise exception 'Cette journée de caisse est clôturée : la date ne peut plus être corrigée' using errcode = '23514';
    end if;
    new.date_initiale := coalesce(old.date_initiale, old.date_effective);
    new.date_corrigee_par := case when current_user in ('authenticated', 'anon') then auth.uid() else new.date_corrigee_par end;
    new.date_corrigee_le := now();
    new.date_douteuse := false;
    -- encaissement_protege remettrait l'ancienne date : on la passe par une variable de transaction.
    perform set_config('scolagrid.date_corrigee', new.id::text || '|' || new.date_effective::text, true);
  else
    new.date_effective := old.date_effective; new.jour_caisse := old.jour_caisse;
    new.date_initiale := old.date_initiale; new.motif_correction_date := old.motif_correction_date;
    new.date_corrigee_par := old.date_corrigee_par; new.date_corrigee_le := old.date_corrigee_le;
  end if;
  return new;
end $$;
-- Avant encaissement_protege et le marquage « après clôture » (ordre alphabétique).
create trigger encaissement_a_dates before insert or update on public.encaissements
  for each row execute function scolagrid.encaissement_dates();
revoke all on function scolagrid.encaissement_dates() from public;

-- Le reçu reste figé, sauf la date corrigée par la direction (contrôlée ci-dessus).
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
  if coalesce(current_setting('scolagrid.date_corrigee', true), '') <> new.id::text || '|' || new.date_effective::text then
    new.date_effective := old.date_effective;
    new.jour_caisse := old.jour_caisse;
  end if;
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

-- Un reçu arrivé après la clôture de SON JOUR DE CAISSE est accepté, mais signalé.
create or replace function scolagrid.marquer_apres_cloture() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.apres_cloture := exists (
    select 1 from public.clotures_caisse c
    where c.organisation_id = new.organisation_id and c.site_id = new.site_id
      and c.encaisse_par = new.encaisse_par and c.jour = new.jour_caisse);
  return new;
end $$;

create or replace function scolagrid.annulation_journee_close() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.statut = 'annule' and old.statut = 'valide'
     and nullif(current_setting('request.jwt.claim.sub', true), '') is not null
     and exists (select 1 from public.clotures_caisse c
                 where c.organisation_id = old.organisation_id and c.site_id = old.site_id
                   and c.encaisse_par = old.encaisse_par and c.jour = old.jour_caisse)
     and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu') then
    raise exception 'Journée clôturée : l''annulation demande le droit « annuler un reçu »' using errcode = '42501';
  end if;
  return new;
end $$;

-- La clôture compte les reçus par JOUR DE CAISSE.
create or replace function scolagrid.cloture_calculee() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  sorties bigint;
  avant record;
begin
  if tg_op = 'UPDATE' then
    raise exception 'Une clôture de caisse ne se modifie pas' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext(new.organisation_id::text || new.site_id::text || new.encaisse_par::text || new.jour::text));
  select coalesce(sum(total_gnf) filter (where mode = 'especes'), 0),
         count(*),
         coalesce(sum(total_gnf) filter (where mode <> 'especes'), 0)
    into new.attendu_especes, new.nb_recus, new.total_autres_modes
  from public.encaissements
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and jour_caisse = new.jour and statut = 'valide';
  select coalesce(sum(montant_gnf), 0) into sorties from public.remboursements
  where organisation_id = new.organisation_id and site_id = new.site_id and verse_par = new.encaisse_par
    and verse_le = new.jour and statut = 'verse' and mode = 'especes';
  sorties := sorties + (select coalesce(sum(montant_gnf), 0) from public.depenses
    where organisation_id = new.organisation_id and site_id = new.site_id and sortie_par = new.encaisse_par
      and sortie_le = new.jour and statut = 'sortie');
  select count(*) as n, coalesce(sum(attendu_especes), 0) as attendu, coalesce(sum(nb_recus), 0) as recus,
         coalesce(sum(total_autres_modes), 0) as autres
    into avant
  from public.clotures_caisse
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and jour = new.jour;
  new.rang := avant.n + 1;
  new.attendu_especes := new.attendu_especes - sorties - avant.attendu;
  new.nb_recus := new.nb_recus - avant.recus;
  new.total_autres_modes := new.total_autres_modes - avant.autres;
  if avant.n > 0 and new.nb_recus <= 0 and new.attendu_especes = 0 then
    raise exception 'Rien de nouveau à clôturer depuis la dernière clôture' using errcode = '23505';
  end if;
  new.ecart := new.compte_especes - new.attendu_especes;
  if new.ecart <> 0 and new.justification is null then
    raise exception 'Un écart de caisse doit être justifié' using errcode = '23514';
  end if;
  return new;
end $$;

-- Dépenses : une sortie directe entre dans la caisse du jour où elle est SAISIE
-- (la date de la dépense reste celle choisie). Jamais une journée à venir.
create or replace function scolagrid.depense_dates() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.recu_serveur_le := now();
    if new.statut = 'sortie' then
      new.sortie_le := least(coalesce((new.created_at at time zone 'UTC')::date, current_date), current_date);
    end if;
  else
    new.recu_serveur_le := old.recu_serveur_le;
    if new.sortie_le is distinct from old.sortie_le and new.sortie_le > current_date then
      new.sortie_le := current_date;
    end if;
  end if;
  return new;
end $$;
-- Après depense_controle (ordre alphabétique).
create trigger depense_z_dates before insert or update on public.depenses
  for each row execute function scolagrid.depense_dates();
revoke all on function scolagrid.depense_dates() from public;

-- Remboursements : jamais versés dans une journée à venir.
create or replace function scolagrid.remboursement_dates() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.recu_serveur_le := now();
  else
    new.recu_serveur_le := old.recu_serveur_le;
  end if;
  if new.verse_le is not null and new.verse_le > current_date then
    new.verse_le := current_date;
  end if;
  return new;
end $$;
create trigger remboursement_z_dates before insert or update on public.remboursements
  for each row execute function scolagrid.remboursement_dates();
revoke all on function scolagrid.remboursement_dates() from public;
