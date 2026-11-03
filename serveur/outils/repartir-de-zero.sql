-- Vide TOUTES les données d'un environnement : écoles, élèves, argent, personnel,
-- postes et comptes de connexion. Garde la structure (tables, règles, migrations)
-- et les réglages du serveur (scolagrid.reglages : SMS…).
-- Variable psql : mode (compter | effacer). N'affiche que des nombres : le journal est public.
\set ON_ERROR_STOP on
begin;
select string_agg(format('%s : %s', t, n), E'\n' order by t) as avant from (
  select c.relname as t, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text as n
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind in ('r', 'p')
  union all
  select 'comptes de connexion (auth.users)', (select count(*) from auth.users)::text
) x \gset
\echo '===== Lignes présentes ====='
\echo :avant

select (:'mode' = 'effacer') as effacer \gset
\if :effacer
  -- Les tables d'argent et d'historique refusent normalement toute suppression
  -- (déclencheurs) : on les contourne pour cette seule transaction.
  set local session_replication_role = replica;
  do $$
  declare t record; n bigint;
  begin
    for t in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
             where s.nspname = 'public' and c.relkind = 'r' order by c.relname loop
      execute format('delete from public.%I', t.relname);
      get diagnostics n = row_count;
      raise notice '% : % ligne(s) effacée(s)', t.relname, n;
    end loop;
    delete from scolagrid.essais_code;
  end $$;
  set local session_replication_role = origin;
  -- Les comptes, en mode normal : leurs sessions et identités suivent (cascade).
  do $$ declare n bigint; begin
    delete from auth.users;
    get diagnostics n = row_count;
    raise notice 'comptes de connexion : % effacé(s)', n;
  end $$;
  commit;
  \echo '===== Tout est effacé : on repart de zéro (inscription de l''école, puis mise en route). ====='
\else
  rollback;
  \echo '===== Comptage seulement : rien n''a été effacé. ====='
\endif
