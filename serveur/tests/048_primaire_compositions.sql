-- Test de la migration 048 : au primaire, seulement la composition par défaut.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
begin;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
select id as annee from public.annees_scolaires where organisation_id = :'org' and en_cours \gset
insert into public.types_evaluation (organisation_id, libelle, poids) values (:'org', 'Évaluation', 1)
  on conflict (organisation_id, libelle) do nothing;
insert into public.types_evaluation (organisation_id, libelle, poids, unique_par_periode) values (:'org', 'Composition', 2, true)
  on conflict (organisation_id, libelle) do nothing;
-- Une période vierge du primaire et une du collège, aux mêmes dates.
delete from public.periodes_evaluation where annee_id = :'annee' and cycle in ('primaire', 'college') and ordre = 6;
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', 'primaire', 6, '1er trimestre', '2026-10-01', '2026-12-30', 10) returning id as prim \gset
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', 'college', 6, '1er semestre', '2026-10-01', '2026-12-30', 20) returning id as coll \gset
select scolagrid.sessions_par_defaut(:'prim'), scolagrid.sessions_par_defaut(:'coll');
select set_config('test.prim', :'prim', false), set_config('test.coll', :'coll', false);
do $$ declare l text; n integer; begin
  select string_agg(libelle || ' ' || debut || '→' || fin, ' | ' order by ordre) into l
    from public.sessions_evaluation where periode_id = current_setting('test.prim')::uuid;
  assert l = 'Composition du 1er trimestre 2026-12-17→2026-12-30', l;
  select count(*) into n from public.sessions_evaluation where periode_id = current_setting('test.coll')::uuid;
  assert n = 4, format('Collège : octobre, novembre, décembre, composition (%s)', n);
end $$;
rollback;
\echo '048 primaire, compositions : OK'
