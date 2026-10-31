-- Test de la migration 016 : pièces du dossier.
-- S : secrétaire (inscrit). G : enseignant (voit, ne change pas).

\set ON_ERROR_STOP on
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

begin;
select pg_temp.connecte(:'s');
set local role authenticated;
update public.eleves set pieces_dossier = 'acte_naissance,photo'
  where id = 'e0000000-0000-0000-0000-000000000002';
do $$ begin
  assert (select pieces_dossier from public.eleves where id = 'e0000000-0000-0000-0000-000000000002')
    = 'acte_naissance,photo', 'La secrétaire coche les pièces';
  begin
    update public.eleves set pieces_dossier = 'Acte; DROP' where id = 'e0000000-0000-0000-0000-000000000002';
    raise exception 'Liste de pièces mal formée acceptée';
  exception when check_violation then null;
  end;
end $$;
commit;

begin;
select pg_temp.connecte(:'g');
set local role authenticated;
update public.eleves set pieces_dossier = null where id = 'e0000000-0000-0000-0000-000000000002';
commit;
do $$ begin
  assert (select pieces_dossier from public.eleves where id = 'e0000000-0000-0000-0000-000000000002')
    = 'acte_naissance,photo', 'L''enseignant ne change pas les pièces';
end $$;
\echo 'Test 016 : tout est conforme.'
