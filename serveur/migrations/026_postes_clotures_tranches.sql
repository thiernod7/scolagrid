-- 026 : postes validés par la direction, clôtures complémentaires, tranches en mois.
--
-- Postes : le fondateur ou le directeur du site active un poste directement ;
-- pour les autres, le poste attend la validation de la direction. En attente,
-- il voit les données mais n'inscrit pas et n'encaisse pas.
-- Clôture de caisse : après une clôture, les reçus du même jour forment un
-- complément, qui se clôture à son tour (rang 2, 3…).
-- Calendrier : une tranche peut être définie en nombre de mois.

-- Tranches en mois ----------------------------------------------------------------------

alter table public.tranches_annee add column mois integer check (mois is null or mois between 1 and 12);

-- Postes à valider ----------------------------------------------------------------------

alter table public.postes drop constraint postes_statut_check;
alter table public.postes add constraint postes_statut_check check (statut in ('a_valider', 'actif', 'bloque'));

create or replace function public.activer_poste(
  organisation uuid, site uuid, nom text, plateforme text default null, version_app text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  suivant integer;
  poste public.postes;
begin
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  if not scolagrid.travaille_sur(organisation, site) then
    raise exception 'Vous ne travaillez pas sur ce site' using errcode = '42501';
  end if;
  perform 1 from public.organisations where id = organisation for update;
  select coalesce(max(numero), 0) + 1 into suivant from public.postes where organisation_id = organisation;
  if suivant > 2000 then
    raise exception 'Nombre maximal de postes atteint' using errcode = '54000';
  end if;
  insert into public.postes (organisation_id, site_id, numero, code, nom, plateforme, version_app, user_id, derniere_synchro, statut)
  values (organisation, site, suivant, scolagrid.code_poste(suivant), trim(nom),
          left(plateforme, 20), left(version_app, 20), moi, now(),
          -- La direction active elle-même ; les autres attendent sa validation.
          case when scolagrid.gere_perimetre(organisation, site) then 'actif' else 'a_valider' end)
  returning * into poste;
  return jsonb_build_object('id', poste.id, 'code', poste.code, 'statut', poste.statut);
end $$;
revoke all on function public.activer_poste(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.activer_poste(uuid, uuid, text, text, text) to authenticated;

-- Un poste qui n'est pas actif n'inscrit pas et n'encaisse pas.
create or replace function scolagrid.poste_actif() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  if new.poste_id is not null then
    select statut into s from public.postes where id = new.poste_id;
    if s is distinct from 'actif' and s is not null then
      raise exception 'Ce poste n''est pas validé par la direction' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function scolagrid.poste_actif() from public;
create trigger poste_actif before insert on public.encaissements
  for each row execute function scolagrid.poste_actif();
create trigger poste_actif before insert on public.inscriptions
  for each row execute function scolagrid.poste_actif();

-- Clôtures complémentaires ---------------------------------------------------------------

alter table public.clotures_caisse add column rang integer not null default 1 check (rang between 1 and 50);
alter table public.clotures_caisse drop constraint clotures_caisse_organisation_id_site_id_encaisse_par_jour_key;
alter table public.clotures_caisse add constraint clotures_caisse_jour_rang unique (organisation_id, site_id, encaisse_par, jour, rang);

-- Chaque clôture couvre ce qui n'a pas encore été clôturé ce jour-là.
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
    and encaisse_par = new.encaisse_par and date_effective = new.jour and statut = 'valide';
  select coalesce(sum(montant_gnf), 0) into sorties from public.remboursements
  where organisation_id = new.organisation_id and site_id = new.site_id and verse_par = new.encaisse_par
    and verse_le = new.jour and statut = 'verse' and mode = 'especes';
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
