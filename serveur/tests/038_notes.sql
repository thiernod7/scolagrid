-- Test de la migration 038 : notes (périodes, types, évaluations, notes, clôture).
-- D : directeur (planifie). G : enseignant (saisit). S : secrétaire (lit, ne saisit pas).
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
select id as annee from public.annees_scolaires where organisation_id = :'org' and en_cours \gset
select c.id as classe, c.niveau_id as niveau, n.cycle from public.classes c join public.niveaux n on n.id = c.niveau_id
  where c.organisation_id = :'org' order by c.created_at limit 1 \gset
select id as matiere from public.matieres where niveau_id = :'niveau' limit 1 \gset
select e.id as eleve from public.eleves e where e.organisation_id = :'org' limit 1 \gset
select set_config('test.org', :'org', false), set_config('test.annee', :'annee', false), set_config('test.cycle', coalesce(:'cycle', 'college'), false);

-- Le directeur crée la période et les types.
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', coalesce(:'cycle', 'college'), 1, '1er semestre', '2026-10-01', '2027-01-31', 20) returning id as periode \gset
insert into public.types_evaluation (organisation_id, libelle, poids) values (:'org', 'Évaluation', 1) returning id as t_eval \gset
insert into public.types_evaluation (organisation_id, libelle, poids, unique_par_periode) values (:'org', 'Composition', 2, true) returning id as t_compo \gset
select set_config('test.periode', :'periode', false), set_config('test.compo', :'t_compo', false),
       set_config('test.classe', :'classe', false), set_config('test.matiere', :'matiere', false), set_config('test.eleve', :'eleve', false);
reset role;

-- La secrétaire lit mais ne crée pas d'évaluation.
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.periodes_evaluation where id = current_setting('test.periode')::uuid) = 1, 'La secrétaire lit les périodes';
  begin
    insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
      values (current_setting('test.org')::uuid, current_setting('test.periode')::uuid, current_setting('test.classe')::uuid,
              current_setting('test.matiere')::uuid, current_setting('test.compo')::uuid, '2026-11-10');
    raise exception 'ÉCHEC : la secrétaire a créé une évaluation';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- L'enseignant crée une composition et saisit les notes.
select pg_temp.connecte(:'g');
set local role authenticated;
insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'classe', :'matiere', :'t_compo', '2026-11-10') returning id as ev \gset
select set_config('test.ev', :'ev', false);
insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat) values (:'org', :'ev', :'eleve', 14.5, 'note');
do $$ begin
  assert (select bareme from public.notes where evaluation_id = current_setting('test.ev')::uuid) = 20, 'Barème de la période gardé';
  begin
    insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
      values (current_setting('test.org')::uuid, current_setting('test.periode')::uuid, current_setting('test.classe')::uuid,
              current_setting('test.matiere')::uuid, current_setting('test.compo')::uuid, '2026-12-10');
    raise exception 'ÉCHEC : deux compositions dans la période';
  exception when unique_violation then null;
  end;
  begin
    update public.notes set valeur = 25 where evaluation_id = current_setting('test.ev')::uuid;
    raise exception 'ÉCHEC : note au-dessus du barème';
  exception when check_violation then null;
  end;
  -- Un absent justifié n'a pas de valeur.
  update public.notes set etat = 'absent_justifie', valeur = 12 where evaluation_id = current_setting('test.ev')::uuid;
  assert (select valeur is null from public.notes where evaluation_id = current_setting('test.ev')::uuid), 'Absent : pas de note';
  update public.notes set etat = 'note', valeur = 14.5 where evaluation_id = current_setting('test.ev')::uuid;
  begin
    update public.periodes_evaluation set statut = 'cloturee' where id = current_setting('test.periode')::uuid;
    if (select statut from public.periodes_evaluation where id = current_setting('test.periode')::uuid) = 'cloturee' then
      raise exception 'ÉCHEC : l''enseignant a clôturé la période';
    end if;
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Le directeur clôture : tout est figé ; il ne rouvre pas (le fondateur seulement).
select pg_temp.connecte(:'d');
set local role authenticated;
update public.periodes_evaluation set statut = 'cloturee' where id = :'periode';
do $$ begin
  assert (select cloturee_par from public.periodes_evaluation where id = current_setting('test.periode')::uuid)
    = '44444444-4444-4444-4444-444444444444', 'Clôture tracée';
  begin
    update public.notes set valeur = 16 where evaluation_id = current_setting('test.ev')::uuid;
    raise exception 'ÉCHEC : note modifiée après la clôture';
  exception when check_violation then null;
  end;
  begin
    update public.periodes_evaluation set statut = 'ouverte' where id = current_setting('test.periode')::uuid;
    raise exception 'ÉCHEC : le directeur a rouvert la période';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select pg_temp.connecte(:'a');
set local role authenticated;
update public.periodes_evaluation set statut = 'ouverte' where id = :'periode';
delete from public.evaluations where id = :'ev';
reset role;
do $$ begin
  assert (select count(*) from public.notes where evaluation_id = current_setting('test.ev')::uuid) = 0, 'Évaluation supprimée avec ses notes';
end $$;
rollback;
\echo '038 notes : OK'
