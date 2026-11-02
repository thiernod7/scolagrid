-- Test de la migration 027 : le poste d'un appareil repris par un autre compte.
-- D : directeur du site 1 (active le poste). S : secrétaire du site 1 (le reprend).

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset

begin;
select pg_temp.connecte(:'d');
set local role authenticated;
select (public.activer_poste(:'org_a', :'site_1', 'PC partagé') ->> 'id') as poste \gset
commit;
select set_config('test.poste', :'poste', false);

-- La secrétaire reprend l'appareil : elle voit le poste, signale la synchro,
-- mais ne le renomme pas et ne change pas son statut.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
update public.postes set derniere_synchro = '2030-01-01', nom = 'Renommé', statut = 'bloque' where id = :'poste';
do $$ begin
  assert (select count(*) from public.postes where id = current_setting('test.poste')::uuid) = 1, 'La secrétaire voit le poste';
end $$;
commit;
do $$ begin
  assert (select derniere_synchro = '2030-01-01' and nom = 'PC partagé' and statut = 'actif'
          from public.postes where id = current_setting('test.poste')::uuid), 'Synchro signalée, nom et statut intacts';
end $$;

delete from public.postes where id = :'poste';
\echo 'Test 027 : tout est conforme.'
