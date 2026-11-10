-- Test de la migration 041 : sessions d'évaluation (fenêtre, type, clôture emboîtée).
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
select c.id as classe, c.niveau_id as niveau from public.classes c where c.organisation_id = :'org' order by c.created_at limit 1 \gset
select id as matiere from public.matieres where niveau_id = :'niveau' limit 1 \gset
select e.id as eleve from public.eleves e where e.organisation_id = :'org' limit 1 \gset

-- La période et les types (comme le fait l'app), puis les sessions par défaut.
insert into public.types_evaluation (organisation_id, libelle, poids) values (:'org', 'Évaluation', 1)
  on conflict (organisation_id, libelle) do nothing;
insert into public.types_evaluation (organisation_id, libelle, poids, unique_par_periode) values (:'org', 'Composition', 2, true)
  on conflict (organisation_id, libelle) do nothing;
select id as t_eval from public.types_evaluation where organisation_id = :'org' and libelle = 'Évaluation' \gset
select id as t_compo from public.types_evaluation where organisation_id = :'org' and libelle = 'Composition' \gset
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', 'test-041', 1, '1er trimestre', '2026-10-01', '2026-12-19', 10) returning id as periode \gset
select scolagrid.sessions_par_defaut(:'periode');
do $$ declare n integer; l text; begin
  select count(*) into n from public.sessions_evaluation where periode_id = (select id from public.periodes_evaluation where cycle = 'test-041');
  assert n = 3, format('Octobre, novembre, composition : %s sessions', n);
  select string_agg(libelle || ' ' || debut || '→' || fin, ' | ' order by ordre) into l
    from public.sessions_evaluation where periode_id = (select id from public.periodes_evaluation where cycle = 'test-041');
  assert l = 'Évaluation d''octobre 2026-10-01→2026-10-31 | Évaluation de novembre 2026-11-01→2026-12-05 | Composition du 1er trimestre 2026-12-06→2026-12-19',
    l;
end $$;
select id as s_oct from public.sessions_evaluation where periode_id = :'periode' and ordre = 1 \gset
select id as s_compo from public.sessions_evaluation where periode_id = :'periode' and ordre = 3 \gset
select set_config('test.org', :'org', false), set_config('test.periode', :'periode', false), set_config('test.classe', :'classe', false),
       set_config('test.matiere', :'matiere', false), set_config('test.s_oct', :'s_oct', false), set_config('test.t_compo', :'t_compo', false);

-- L'enseignant place son épreuve d'octobre le 5 novembre : hors fenêtre, refusée.
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  insert into public.evaluations (organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation)
    values (current_setting('test.org')::uuid, current_setting('test.periode')::uuid, current_setting('test.s_oct')::uuid,
            current_setting('test.classe')::uuid, current_setting('test.matiere')::uuid, current_setting('test.t_compo')::uuid, '2026-11-05');
  assert false, 'Épreuve hors fenêtre acceptée';
exception when check_violation then null;
end $$;
-- Dans la fenêtre : acceptée, et elle prend le type de la session (même si l'app envoie un autre type).
insert into public.evaluations (organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'s_oct', :'classe', :'matiere', :'t_compo', '2026-10-20') returning id as ev \gset
select set_config('test.ev', :'ev', false);
do $$ begin
  assert (select t.libelle from public.evaluations e join public.types_evaluation t on t.id = e.type_id
          where e.id = current_setting('test.ev')::uuid) = 'Évaluation', 'Type de la session';
end $$;
insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat) values (:'org', :'ev', :'eleve', 7, 'note');
reset role;

-- Le directeur clôture la session d'octobre : ses notes sont figées.
select pg_temp.connecte(:'d');
set local role authenticated;
update public.sessions_evaluation set statut = 'cloturee' where id = :'s_oct';
reset role;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  update public.notes set valeur = 9 where evaluation_id = current_setting('test.ev')::uuid;
  assert false, 'Note modifiée dans une session clôturée';
exception when check_violation then null;
end $$;
reset role;
-- Rouverte (planifier_evaluations), la correction passe.
select pg_temp.connecte(:'d');
set local role authenticated;
update public.sessions_evaluation set statut = 'ouverte' where id = :'s_oct';
update public.notes set valeur = 9 where evaluation_id = :'ev';
-- Une session doit rester dans sa période.
do $$ begin
  update public.sessions_evaluation set fin = '2027-01-10' where id = current_setting('test.s_oct')::uuid;
  assert false, 'Session hors période acceptée';
exception when check_violation then null;
end $$;
reset role;
rollback;
\echo '041 sessions : OK'
