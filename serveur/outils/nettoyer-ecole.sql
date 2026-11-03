-- Efface les élèves et l'argent d'UNE école (pour repartir de zéro en essai).
-- Garde : l'école, ses sites, l'année, les niveaux, les classes, les frais,
-- les règles de réduction, le personnel et les postes.
-- Variables psql : ecole (nom exact, sans tenir compte des majuscules), mode (compter | effacer).
-- N'affiche que des nombres : le journal est public.
\set ON_ERROR_STOP on
begin;
select count(*) as nb from public.organisations where lower(trim(nom)) = lower(trim(:'ecole')) \gset
select (:nb = 1) as une_seule \gset
\if :une_seule
\else
  \echo 'Écoles trouvées avec ce nom :' :nb '— rien n''est fait (il en faut exactement une).'
  rollback;
  \quit
\endif
select id as org from public.organisations where lower(trim(nom)) = lower(trim(:'ecole')) \gset
select set_config('nettoyage.org', :'org', true) as fait \gset

create temp table a_effacer (ordre int, nom text) on commit drop;
insert into a_effacer values
  (1, 'lignes_encaissement'), (2, 'remboursements'), (3, 'souscriptions'), (4, 'echeances_eleves'),
  (5, 'reductions_eleves'), (6, 'impressions_documents'), (7, 'historique_eleves'), (8, 'photos_eleves'),
  (9, 'eleves_contacts'), (10, 'encaissements'), (11, 'clotures_caisse'), (12, 'inscriptions'),
  (13, 'contacts'), (14, 'eleves');

-- Comptage avant.
select string_agg(format('%s : %s', nom, n), E'\n' order by ordre) as avant from (
  select a.ordre, a.nom, (xpath('/row/n/text()', query_to_xml(
           format('select count(*) as n from public.%I where organisation_id = %L', a.nom, current_setting('nettoyage.org')),
           false, true, '')))[1]::text as n
  from a_effacer a) x \gset
\echo '===== Lignes de cette école ====='
\echo :avant

select (:'mode' = 'effacer') as effacer \gset
\if :effacer
  -- Les tables d'argent refusent normalement toute suppression (déclencheurs) :
  -- on les contourne pour cette seule transaction. Les suppressions partent quand
  -- même vers les appareils par la synchronisation.
  set local session_replication_role = replica;
  do $$
  declare t record; n bigint;
  begin
    for t in select nom from a_effacer order by ordre loop
      execute format('delete from public.%I where organisation_id = %L', t.nom, current_setting('nettoyage.org'));
      get diagnostics n = row_count;
      raise notice '% : % ligne(s) effacée(s)', t.nom, n;
    end loop;
  end $$;
  set local session_replication_role = origin;
  commit;
  \echo '===== Effacé. Restent : l''école, les sites, l''année, les niveaux, les classes, les frais, le personnel, les postes. ====='
\else
  rollback;
  \echo '===== Comptage seulement : rien n''a été effacé. ====='
\endif
