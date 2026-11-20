-- Test de la migration 044 : qui enseigne quoi ; l'enseignant ne saisit et ne voit que ses classes et matières.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
select id as annee from public.annees_scolaires where organisation_id = :'org' and en_cours \gset
select c.id as classe, c.niveau_id as niveau from public.classes c
  where c.organisation_id = :'org' and exists (select 1 from public.inscriptions i where i.classe_id = c.id) order by c.created_at limit 1 \gset
select id as matiere from public.matieres where niveau_id = :'niveau' order by nom limit 1 \gset
select id as fiche_g, site_id as site_g from public.personnel where user_id = :'g' and organisation_id = :'org' \gset
-- Une deuxième matière du même niveau, une autre classe, et une matière d'un autre niveau.
insert into public.matieres (organisation_id, niveau_id, nom, coefficient) values (:'org', :'niveau', 'Matière 044', 1)
  returning id as autre_matiere \gset
select c.id as autre_classe from public.classes c
  where c.organisation_id = :'org' and c.id <> :'classe' order by c.created_at limit 1 \gset
insert into public.niveaux (organisation_id, cycle, nom, ordre) values (:'org', 'lycee', 'Niveau 044', 99) returning id as autre_niveau \gset
insert into public.matieres (organisation_id, niveau_id, nom, coefficient) values (:'org', :'autre_niveau', 'Matière 044 B', 1)
  returning id as matiere_b \gset
insert into public.types_evaluation (organisation_id, libelle, poids) values (:'org', 'Évaluation', 1)
  on conflict (organisation_id, libelle) do nothing;
select id as t_eval from public.types_evaluation where organisation_id = :'org' and libelle = 'Évaluation' \gset
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', 'test-044', 1, 'Période', '2026-01-01', '2027-06-30', 20) returning id as periode \gset
-- Une épreuve de l'autre classe, créée par la direction.
insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'autre_classe', :'matiere', :'t_eval', current_date) returning id as ev_autre \gset
select set_config('test.org', :'org', false), set_config('test.classe', :'classe', false), set_config('test.matiere', :'matiere', false),
       set_config('test.autre_matiere', :'autre_matiere', false), set_config('test.autre_classe', :'autre_classe', false),
       set_config('test.matiere_b', :'matiere_b', false), set_config('test.periode', :'periode', false),
       set_config('test.t_eval', :'t_eval', false), set_config('test.ev_autre', :'ev_autre', false),
       set_config('test.fiche_g', :'fiche_g', false), set_config('test.site_g', :'site_g', false),
       set_config('test.niveau', :'niveau', false);

-- Sans enseignement, l'enseignant ne crée rien.
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert not scolagrid.lit_notes(current_setting('test.org')::uuid), 'Saisir les notes ne donne plus la lecture de toutes les notes';
  begin
    insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
      values (current_setting('test.org')::uuid, current_setting('test.periode')::uuid, current_setting('test.classe')::uuid,
              current_setting('test.matiere')::uuid, current_setting('test.t_eval')::uuid, current_date);
    assert false, 'Épreuve créée sans enseignement';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.eleves) = 0, 'Aucun élève sans classe';
end $$;
reset role;

-- La direction (D, directeur) l'affecte : cette matière dans cette classe.
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id, debut)
  values (:'org', :'fiche_g', :'classe', :'matiere', current_date - 30);
do $$ begin
  -- Une matière d'un autre niveau : refusée.
  insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id)
    values (current_setting('test.org')::uuid, current_setting('test.fiche_g')::uuid, current_setting('test.classe')::uuid,
            current_setting('test.matiere_b')::uuid);
  assert false, 'Matière d''un autre niveau acceptée';
exception when check_violation then null;
end $$;
reset role;

select pg_temp.connecte(:'g');
set local role authenticated;
insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'classe', :'matiere', :'t_eval', current_date) returning id as ev \gset
select set_config('test.ev', :'ev', false);
insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat)
  select :'org', :'ev', i.eleve_id, 12, 'note' from public.inscriptions i where i.classe_id = :'classe' limit 1;
do $$ begin
  assert (select service from public.evaluations where id = current_setting('test.ev')::uuid)
    = current_setting('test.classe') || '|' || current_setting('test.matiere'), 'Service rempli par le serveur';
  assert (select count(*) from public.notes where evaluation_id = current_setting('test.ev')::uuid) = 1, 'Note saisie';
  -- Une autre matière de la même classe : refusée.
  begin
    insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
      values (current_setting('test.org')::uuid, current_setting('test.periode')::uuid, current_setting('test.classe')::uuid,
              current_setting('test.autre_matiere')::uuid, current_setting('test.t_eval')::uuid, current_date);
    assert false, 'Épreuve d''une autre matière acceptée';
  exception when insufficient_privilege then null;
  end;
  -- Il ne voit ni l'épreuve de l'autre classe, ni ses élèves.
  assert not exists (select 1 from public.evaluations where id = current_setting('test.ev_autre')::uuid), 'Épreuve d''une autre classe visible';
  assert (select count(*) from public.eleves)
    = (select count(distinct eleve_id) from public.inscriptions), 'Seulement les élèves de ses classes';
  assert not exists (select 1 from public.inscriptions where classe_id <> current_setting('test.classe')::uuid), 'Inscriptions d''autres classes visibles';
  assert exists (select 1 from public.periodes_evaluation where id = current_setting('test.periode')::uuid), 'Il lit les périodes';
end $$;
reset role;

-- Professeur principal de l'autre classe : il lit ses épreuves, sans pouvoir y écrire.
update public.classes set professeur_principal_id = :'fiche_g' where id = :'autre_classe';
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert exists (select 1 from public.evaluations where id = current_setting('test.ev_autre')::uuid), 'Le professeur principal lit sa classe';
  update public.evaluations set libelle = 'Changée' where id = current_setting('test.ev_autre')::uuid;
  assert (select libelle is null from public.evaluations where id = current_setting('test.ev_autre')::uuid),
    'Le professeur principal a modifié l''épreuve d''un collègue';
end $$;
reset role;
update public.classes set professeur_principal_id = null where id = :'autre_classe';

-- Enseignement terminé depuis plus de 7 jours : plus de saisie (la lecture reste).
update public.enseignements set debut = current_date - 60, fin = current_date - 10 where personnel_id = :'fiche_g' and classe_id = :'classe';
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  update public.notes set valeur = 15 where evaluation_id = current_setting('test.ev')::uuid;
  assert (select valeur = 12 from public.notes where evaluation_id = current_setting('test.ev')::uuid), 'Note modifiée après la fin';
  assert exists (select 1 from public.evaluations where id = current_setting('test.ev')::uuid), 'Il relit ses anciennes épreuves';
end $$;
reset role;

-- La direction des études saisit partout ; l'enseignant ne gère pas les enseignements.
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'classe', :'autre_matiere', :'t_eval', current_date);
reset role;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id)
    values (current_setting('test.org')::uuid, current_setting('test.fiche_g')::uuid, current_setting('test.classe')::uuid,
            current_setting('test.autre_matiere')::uuid);
  assert false, 'Un enseignant s''est affecté lui-même';
exception when insufficient_privilege then null;
end $$;
-- Son téléphone est actif tout de suite.
do $$ declare r jsonb; begin
  r := public.activer_poste(current_setting('test.org')::uuid, nullif(current_setting('test.site_g'), '')::uuid, 'Téléphone de G', 'android', '0.9');
  assert r ->> 'statut' = 'actif', 'Téléphone d''enseignant actif : ' || (r ->> 'statut');
end $$;
reset role;
rollback;
\echo '044 enseignements : OK'
