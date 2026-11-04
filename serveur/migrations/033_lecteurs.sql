-- 033 : utilisateurs « lecteurs » et droits de consultation.
--
-- Une nouvelle fonction, « lecteur » : aucune écriture (aucun droit par défaut).
-- Ce qu'une personne VOIT devient un droit comme les autres, accordé ou retiré
-- fiche par fiche :
--   voir_familles   parents et tuteurs (noms, téléphones)
--   voir_caisse     reçus, clôtures, remboursements, échéances des élèves
--   voir_personnel  la liste du personnel
-- (consulter_tableau_bord existait déjà : il donne aussi accès aux chiffres de la caisse.)
-- Les fonctions qui voyaient déjà ces données les gardent par défaut.
--
-- La synchronisation ne sait pas appeler de fonction : on range donc sur chaque
-- rattachement ce qu'il permet de lire (lit_familles, lit_caisse, lit_personnel),
-- recalculé à chaque changement de fonction ou de droit.

alter table public.rattachements drop constraint rattachements_role_check;
alter table public.rattachements add constraint rattachements_role_check check (role in (
  'fondateur', 'directeur', 'directeur_etudes', 'surveillant', 'secretaire',
  'comptable', 'caissier', 'enseignant', 'autre', 'lecteur'));

alter table public.affectations drop constraint affectations_fonction_check;
alter table public.affectations add constraint affectations_fonction_check check (fonction in (
  'fondateur', 'directeur', 'directeur_etudes', 'surveillant', 'secretaire',
  'comptable', 'caissier', 'enseignant', 'autre', 'lecteur'));

alter table public.droits_personnel drop constraint droits_personnel_droit_check;
alter table public.droits_personnel add constraint droits_personnel_droit_check check (droit in (
  'valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps', 'planifier_evaluations',
  'saisir_notes', 'faire_appel', 'justifier_absence', 'preparer_paie', 'valider_paie',
  'verser_paie', 'consulter_tableau_bord', 'autoriser_depense',
  'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse', 'voir_personnel'));

create or replace function scolagrid.droits_par_defaut(fonction text) returns text[]
language sql immutable set search_path = '' as $$
  select case fonction
    when 'directeur' then array['valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
                                'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord',
                                'gerer_inscriptions', 'voir_familles', 'voir_caisse', 'voir_personnel']
    when 'directeur_etudes' then array['gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence']
    when 'surveillant' then array['faire_appel', 'justifier_absence']
    when 'enseignant' then array['saisir_notes', 'faire_appel']
    when 'secretaire' then array['gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse']
    when 'comptable' then array['consulter_tableau_bord', 'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse']
    when 'caissier' then array['encaisser', 'voir_familles', 'voir_caisse']
    else array[]::text[]   -- lecteur, autre : rien par défaut
  end
$$;

alter table public.rattachements
  add column lit_familles boolean not null default false,
  add column lit_caisse boolean not null default false,
  add column lit_personnel boolean not null default false;

-- Un rattachement donne-t-il ce droit ? Défaut de sa fonction ou droit accordé à la
-- fiche (pour son site ou tout le groupe), et pas retiré.
create or replace function scolagrid.rattachement_a(r public.rattachements, fiche uuid, quel_droit text) returns boolean
language sql stable security definer set search_path = '' as $$
  select r.role = 'fondateur' or (
    (quel_droit = any (scolagrid.droits_par_defaut(r.role))
     or exists (select 1 from public.droits_personnel d
                where d.personnel_id = fiche and d.accorde and d.droit = quel_droit
                  and (d.site_id is null or d.site_id is not distinct from r.site_id)))
    and not exists (select 1 from public.droits_personnel d
                    where d.personnel_id = fiche and not d.accorde and d.droit = quel_droit
                      and (d.site_id is null or d.site_id is not distinct from r.site_id)))
$$;

-- Recalcule ce que les rattachements d'une fiche permettent de lire.
create or replace function scolagrid.recalculer_lectures(fiche uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare org uuid; compte uuid;
begin
  select organisation_id, user_id into org, compte from public.personnel where id = fiche;
  if compte is null then return; end if;
  update public.rattachements r set
    lit_familles = x.familles, lit_caisse = x.caisse, lit_personnel = x.personnel, updated_at = now()
  from (
    select r2.id,
           scolagrid.rattachement_a(r2, fiche, 'voir_familles') as familles,
           scolagrid.rattachement_a(r2, fiche, 'voir_caisse') or scolagrid.rattachement_a(r2, fiche, 'consulter_tableau_bord') as caisse,
           scolagrid.rattachement_a(r2, fiche, 'voir_personnel') as personnel
    from public.rattachements r2 where r2.organisation_id = org and r2.user_id = compte
  ) x
  where r.id = x.id
    and (r.lit_familles, r.lit_caisse, r.lit_personnel) is distinct from (x.familles, x.caisse, x.personnel);
end $$;

-- Le calcul des accès recalcule aussi les lectures.
create or replace function scolagrid.recalculer_acces(fiche uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org uuid; compte uuid; en_poste boolean;
begin
  select organisation_id, user_id, statut = 'actif' into org, compte, en_poste
  from public.personnel where id = fiche;
  if compte is null then return; end if;

  update public.rattachements r
  set actif = en_poste and exists (
    select 1 from public.affectations a
    where a.personnel_id = fiche and a.actif and a.fonction = r.role and a.site_id is not distinct from r.site_id)
  where r.organisation_id = org and r.user_id = compte
    and r.actif is distinct from (en_poste and exists (
      select 1 from public.affectations a
      where a.personnel_id = fiche and a.actif and a.fonction = r.role and a.site_id is not distinct from r.site_id));

  insert into public.rattachements (organisation_id, site_id, user_id, role)
  select org, a.site_id, compte, a.fonction
  from public.affectations a
  where en_poste and a.personnel_id = fiche and a.actif
    and not exists (select 1 from public.rattachements r
                    where r.organisation_id = org and r.user_id = compte
                      and r.role = a.fonction and r.site_id is not distinct from a.site_id);

  perform scolagrid.recalculer_lectures(fiche);
end $$;

-- Un droit accordé ou retiré change ce que la personne lit.
create or replace function scolagrid.apres_droit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform scolagrid.recalculer_lectures(coalesce(new.personnel_id, old.personnel_id));
  return null;
end $$;
create trigger apres_droit after insert or update or delete on public.droits_personnel
  for each row execute function scolagrid.apres_droit();

revoke all on function scolagrid.rattachement_a(public.rattachements, uuid, text), scolagrid.recalculer_lectures(uuid),
  scolagrid.apres_droit() from public;

-- Les comptes existants : leurs lectures d'après leurs fonctions actuelles.
do $$ declare f record; begin
  for f in select id from public.personnel where user_id is not null loop
    perform scolagrid.recalculer_lectures(f.id);
  end loop;
end $$;
