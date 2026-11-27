-- 050 : le périmètre par cycles, et la fonction « Responsable de cycle ».
--
-- Une fonction peut couvrir toute l'école (cycles vide) ou seulement certains cycles
-- (« Collège et lycée » pour un principal). Hors de ses cycles, la personne ne voit
-- aucun élève, aucune note, aucun parent, et ne peut rien y écrire. Le serveur
-- l'applique : règles d'accès (RLS) et synchronisation (table perimetres).
--
-- Responsable de cycle (Principal, Proviseur, Directeur du primaire) : élèves,
-- parents, évaluations et vie scolaire de ses cycles ; ni caisse, ni tableau de
-- bord, ni paie, ni gestion du personnel ou des paramètres de l'école.

-- La fonction --------------------------------------------------------------------------
alter table public.rattachements drop constraint rattachements_role_check;
alter table public.rattachements add constraint rattachements_role_check check (role in (
  'fondateur', 'directeur', 'directeur_etudes', 'responsable_cycle', 'surveillant', 'secretaire',
  'comptable', 'caissier', 'enseignant', 'autre', 'lecteur'));
alter table public.affectations drop constraint affectations_fonction_check;
alter table public.affectations add constraint affectations_fonction_check check (fonction in (
  'fondateur', 'directeur', 'directeur_etudes', 'responsable_cycle', 'surveillant', 'secretaire',
  'comptable', 'caissier', 'enseignant', 'autre', 'lecteur'));

create or replace function scolagrid.droits_par_defaut(fonction text) returns text[]
language sql immutable set search_path = '' as $$
  select case fonction
    when 'directeur' then array['valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
                                'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord',
                                'gerer_inscriptions', 'voir_familles', 'voir_caisse', 'voir_personnel',
                                'autoriser_depense']
    when 'responsable_cycle' then array['gerer_emploi_du_temps', 'planifier_evaluations', 'saisir_notes', 'faire_appel',
                                        'justifier_absence', 'gerer_inscriptions', 'voir_familles', 'voir_personnel']
    when 'directeur_etudes' then array['gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence']
    when 'surveillant' then array['faire_appel', 'justifier_absence']
    when 'enseignant' then array['saisir_notes', 'faire_appel']
    when 'secretaire' then array['gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse']
    when 'comptable' then array['consulter_tableau_bord', 'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse']
    when 'caissier' then array['encaisser', 'voir_familles', 'voir_caisse']
    else array[]::text[]
  end
$$;

-- Les cycles couverts : sur la fonction (saisie par la direction), recopiés sur le rattachement.
alter table public.affectations add column cycles text[]
  check (cycles is null or (cardinality(cycles) between 1 and 6 and array_position(cycles, null) is null));
alter table public.rattachements add column cycles text[];

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

  -- Les cycles du rattachement : ceux de ses fonctions (toute l'école si l'une n'en a pas).
  update public.rattachements r set cycles = x.cycles, updated_at = now()
  from (
    select r2.id,
           case when bool_or(a.cycles is null) then null
                else (select array_agg(distinct c order by c) from public.affectations a2, unnest(a2.cycles) c
                      where a2.personnel_id = fiche and a2.actif and a2.fonction = r2.role
                        and a2.site_id is not distinct from r2.site_id) end as cycles
    from public.rattachements r2
    join public.affectations a on a.personnel_id = fiche and a.actif and a.fonction = r2.role and a.site_id is not distinct from r2.site_id
    where r2.organisation_id = org and r2.user_id = compte
    group by r2.id, r2.role, r2.site_id
  ) x
  where r.id = x.id and r.cycles is distinct from x.cycles;

  perform scolagrid.recalculer_lectures(fiche);
end $$;
revoke all on function scolagrid.recalculer_acces(uuid) from public;

-- Les classes de chacun (synchronisation) --------------------------------------------
-- Une ligne par personne limitée à des cycles et par classe de ces cycles (et de son site).
create table public.perimetres (
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  classe_id uuid not null references public.classes (id) on delete cascade,
  familles boolean not null default false,  -- voit les parents de ces élèves
  notes boolean not null default false,     -- lit les notes de ces classes
  primary key (user_id, classe_id)
);
create index perimetres_organisation_idx on public.perimetres (organisation_id);
alter table public.perimetres owner to postgres;
alter table public.perimetres enable row level security;
revoke all on public.perimetres from anon, authenticated;
grant select on public.perimetres to powersync_role;
grant select on public.perimetres to authenticated;
create policy "le sien" on public.perimetres for select to authenticated using (user_id = auth.uid());

-- Quelqu'un est « limité » s'il n'a dans l'école aucune fonction (hors enseignant) sans cycles.
create or replace function scolagrid.recalculer_perimetres(org uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.perimetres where organisation_id = org;
  insert into public.perimetres (organisation_id, user_id, classe_id, familles, notes)
  select org, r.user_id, c.id, bool_or(r.lit_familles), bool_or(r.lit_notes)
  from public.rattachements r
  join public.classes c on c.organisation_id = org and (r.site_id is null or c.site_id = r.site_id)
  join public.niveaux n on n.id = c.niveau_id
  where r.organisation_id = org and r.actif and r.role <> 'enseignant' and r.cycles is not null
    and n.cycle = any (r.cycles)
    and not exists (select 1 from public.rattachements r2
                    where r2.organisation_id = org and r2.user_id = r.user_id and r2.actif
                      and r2.role <> 'enseignant' and r2.cycles is null)
  group by r.user_id, c.id;
end $$;
revoke all on function scolagrid.recalculer_perimetres(uuid) from public;

create or replace function scolagrid.apres_perimetre() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform scolagrid.recalculer_perimetres(coalesce(new.organisation_id, old.organisation_id));
  return null;
end $$;
revoke all on function scolagrid.apres_perimetre() from public;
create trigger perimetre_rattachement after insert or update or delete on public.rattachements
  for each row execute function scolagrid.apres_perimetre();
create trigger perimetre_classe after insert or update of niveau_id, site_id on public.classes
  for each row execute function scolagrid.apres_perimetre();
create trigger perimetre_niveau after update of cycle on public.niveaux
  for each row execute function scolagrid.apres_perimetre();
alter publication powersync add table public.perimetres;

-- Ce que chacun voit et fait (règles d'accès) ---------------------------------------------
-- Tous les élèves : une fonction (hors enseignant) sans limite de cycles.
create or replace function scolagrid.lit_tous_eleves(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and role <> 'enseignant' and cycles is null)
$$;

-- Les classes de mon périmètre (si je suis limité à des cycles).
create or replace function scolagrid.classes_perimetre() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select classe_id from public.perimetres where user_id = auth.uid()
$$;

-- Cette classe est-elle à ma portée ? (toute l'école, ou une classe de mes cycles)
create or replace function scolagrid.couvre_classe(org uuid, classe uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.lit_tous_eleves(org) or classe in (select scolagrid.classes_perimetre())
$$;

-- Ce cycle est-il à ma portée ?
create or replace function scolagrid.couvre_cycle(org uuid, cycle text) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.lit_tous_eleves(org)
      or exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and role <> 'enseignant' and cycle = any (cycles))
$$;

-- Toutes les notes : lire les notes, sans limite de cycles.
create or replace function scolagrid.lit_toutes_notes(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and lit_notes and cycles is null)
$$;

-- Mes classes : où j'enseigne, dont je suis professeur principal, et celles de mes cycles.
create or replace function scolagrid.mes_classes() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select classe_id from public.enseignements where personnel_id in (select scolagrid.mes_fiches())
  union
  select id from public.classes where professeur_principal_id in (select scolagrid.mes_fiches())
  union
  select scolagrid.classes_perimetre()
$$;

create or replace function scolagrid.lit_service(org uuid, classe uuid, matiere uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.lit_toutes_notes(org)
      or (scolagrid.lit_notes(org) and classe in (select scolagrid.classes_perimetre()))
      or exists (select 1 from public.enseignements
                 where classe_id = classe and matiere_id = matiere and personnel_id in (select scolagrid.mes_fiches()))
      or exists (select 1 from public.classes
                 where id = classe and professeur_principal_id in (select scolagrid.mes_fiches()))
$$;

-- Je lis les notes de cet élève ? (toutes les notes, ou un élève de mes classes)
create or replace function scolagrid.lit_notes_eleve(org uuid, eleve uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.lit_toutes_notes(org)
      or (scolagrid.lit_notes(org) and eleve in (select i.eleve_id from public.inscriptions i
                                                where i.classe_id in (select scolagrid.classes_perimetre())))
$$;

create or replace function scolagrid.peut_saisir(org uuid, classe uuid, matiere uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (scolagrid.a_le_droit_quelque_part(org, 'planifier_evaluations') and scolagrid.couvre_classe(org, classe))
      or (scolagrid.a_le_droit_quelque_part(org, 'saisir_notes')
          and exists (select 1 from public.enseignements
                      where classe_id = classe and matiere_id = matiere
                        and personnel_id in (select scolagrid.mes_fiches())
                        and debut <= current_date and (fin is null or fin + 7 >= current_date)))
$$;

create or replace function scolagrid.peut_apprecier(org uuid, eleve uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (scolagrid.a_le_droit_quelque_part(org, 'planifier_evaluations')
          and (scolagrid.lit_tous_eleves(org) or eleve in (select scolagrid.mes_eleves())))
      or exists (select 1 from public.inscriptions i join public.classes c on c.id = i.classe_id
                 where i.eleve_id = eleve and c.professeur_principal_id in (select scolagrid.mes_fiches()))
$$;

-- Familles : les parents des élèves de mes cycles seulement.
create or replace function scolagrid.voit_contact(org uuid, contact uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (scolagrid.voit_familles(org) and scolagrid.lit_tous_eleves(org))
      or (scolagrid.voit_familles(org) and contact in (
            select ec.contact_id from public.eleves_contacts ec join public.inscriptions i on i.eleve_id = ec.eleve_id
            where i.classe_id in (select scolagrid.classes_perimetre())))
$$;

do $$ declare f text; begin
  foreach f in array array['lit_tous_eleves(uuid)', 'classes_perimetre()', 'couvre_classe(uuid, uuid)', 'couvre_cycle(uuid, text)',
    'lit_toutes_notes(uuid)', 'mes_classes()', 'lit_service(uuid, uuid, uuid)', 'lit_notes_eleve(uuid, uuid)',
    'peut_saisir(uuid, uuid, uuid)', 'peut_apprecier(uuid, uuid)', 'voit_contact(uuid, uuid)'] loop
    execute format('revoke all on function scolagrid.%s from public', f);
    execute format('grant execute on function scolagrid.%s to authenticated', f);
  end loop;
end $$;

-- La caisse : un responsable de cycle ne la voit pas (sauf « voir la caisse » accordé).
create or replace function scolagrid.voit_caisse(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (scolagrid.voit_familles(org) and scolagrid.lit_tous_eleves(org))
      or scolagrid.a_le_droit_quelque_part(org, 'consulter_tableau_bord')
      or scolagrid.lit_caisse(org)
$$;

-- Élèves et inscriptions : écrire seulement dans ses cycles.
drop policy "inscripteur modifie" on public.eleves;
create policy "inscripteur modifie" on public.eleves for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions')
         and (scolagrid.lit_tous_eleves(organisation_id) or id in (select scolagrid.mes_eleves())))
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'));
drop policy "inscripteur ajoute" on public.inscriptions;
create policy "inscripteur ajoute" on public.inscriptions for insert to authenticated
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions') and scolagrid.couvre_classe(organisation_id, classe_id));
drop policy "inscripteur modifie" on public.inscriptions;
create policy "inscripteur modifie" on public.inscriptions for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions') and scolagrid.couvre_classe(organisation_id, classe_id))
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions') and scolagrid.couvre_classe(organisation_id, classe_id));
drop policy "membres lisent" on public.historique_eleves;
create policy "membres lisent" on public.historique_eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations())
         and (scolagrid.lit_tous_eleves(organisation_id) or eleve_id in (select scolagrid.mes_eleves())));

-- Familles.
drop policy "familles : lecture" on public.contacts;
create policy "familles : lecture" on public.contacts for select to authenticated
  using (scolagrid.voit_contact(organisation_id, id));
drop policy "familles : lecture" on public.eleves_contacts;
create policy "familles : lecture" on public.eleves_contacts for select to authenticated
  using (scolagrid.voit_familles(organisation_id)
         and (scolagrid.lit_tous_eleves(organisation_id) or eleve_id in (select scolagrid.mes_eleves())));

-- Notes : lire toutes les notes, ou celles de ses cycles.
drop policy "notes : lecture" on public.evaluations;
create policy "notes : lecture" on public.evaluations for select to authenticated
  using (scolagrid.lit_toutes_notes(organisation_id)
         or (scolagrid.lit_notes(organisation_id) and classe_id in (select scolagrid.classes_perimetre())));
do $$ declare t text; begin
  foreach t in array array['notes', 'appreciations', 'notes_historique', 'decisions_annee'] loop
    execute format('drop policy "notes : lecture" on public.%I', t);
    execute format('create policy "notes : lecture" on public.%I for select to authenticated using (scolagrid.lit_notes_eleve(organisation_id, eleve_id))', t);
  end loop;
end $$;

-- Décisions de fin d'année : seulement pour les élèves de ses cycles.
drop policy "direction : décision" on public.decisions_annee;
create policy "direction : décision" on public.decisions_annee for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')
              and (scolagrid.lit_tous_eleves(organisation_id)
                   or inscription_id in (select id from public.inscriptions where classe_id in (select scolagrid.classes_perimetre()))));
drop policy "direction : décision (modif)" on public.decisions_annee;
create policy "direction : décision (modif)" on public.decisions_annee for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')
         and (scolagrid.lit_tous_eleves(organisation_id) or eleve_id in (select scolagrid.mes_eleves()))) with check (true);
drop policy "direction : décision (suppression)" on public.decisions_annee;
create policy "direction : décision (suppression)" on public.decisions_annee for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')
         and (scolagrid.lit_tous_eleves(organisation_id) or eleve_id in (select scolagrid.mes_eleves())));

-- Réglages des évaluations : ses cycles seulement ; ce qui vaut pour toute l'école
-- (types, règles de calcul), seulement sans limite de cycles.
drop policy "direction : périodes" on public.periodes_evaluation;
create policy "direction : périodes" on public.periodes_evaluation for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.couvre_cycle(organisation_id, cycle));
drop policy "direction : périodes (modif)" on public.periodes_evaluation;
create policy "direction : périodes (modif)" on public.periodes_evaluation for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.couvre_cycle(organisation_id, cycle))
  with check (scolagrid.couvre_cycle(organisation_id, cycle));

create or replace function scolagrid.couvre_periode(org uuid, periode uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select scolagrid.couvre_cycle(org, cycle) from public.periodes_evaluation where id = periode), false)
$$;
revoke all on function scolagrid.couvre_periode(uuid, uuid) from public;
grant execute on function scolagrid.couvre_periode(uuid, uuid) to authenticated;
drop policy "direction : sessions" on public.sessions_evaluation;
create policy "direction : sessions" on public.sessions_evaluation for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.couvre_periode(organisation_id, periode_id));
drop policy "direction : sessions (modif)" on public.sessions_evaluation;
create policy "direction : sessions (modif)" on public.sessions_evaluation for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.couvre_periode(organisation_id, periode_id))
  with check (scolagrid.couvre_periode(organisation_id, periode_id));
drop policy "direction : sessions (suppression)" on public.sessions_evaluation;
create policy "direction : sessions (suppression)" on public.sessions_evaluation for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.couvre_periode(organisation_id, periode_id));

drop policy "direction : types" on public.types_evaluation;
create policy "direction : types" on public.types_evaluation for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.lit_tous_eleves(organisation_id));
drop policy "direction : types (modif)" on public.types_evaluation;
create policy "direction : types (modif)" on public.types_evaluation for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations') and scolagrid.lit_tous_eleves(organisation_id)) with check (true);

-- Qui enseigne quoi : seulement dans ses classes.
drop policy "direction ajoute" on public.enseignements;
create policy "direction ajoute" on public.enseignements for insert to authenticated
  with check (scolagrid.gere_enseignements(organisation_id) and scolagrid.couvre_classe(organisation_id, classe_id));
drop policy "direction modifie" on public.enseignements;
create policy "direction modifie" on public.enseignements for update to authenticated
  using (scolagrid.gere_enseignements(organisation_id) and scolagrid.couvre_classe(organisation_id, classe_id))
  with check (scolagrid.couvre_classe(organisation_id, classe_id));
drop policy "direction supprime" on public.enseignements;
create policy "direction supprime" on public.enseignements for delete to authenticated
  using (scolagrid.gere_enseignements(organisation_id) and scolagrid.couvre_classe(organisation_id, classe_id));

-- Les périmètres de tout le monde, une première fois.
do $$ declare f record; o record; begin
  for f in select id from public.personnel where user_id is not null loop
    perform scolagrid.recalculer_acces(f.id);
  end loop;
  for o in select id from public.organisations loop
    perform scolagrid.recalculer_perimetres(o.id);
  end loop;
end $$;
