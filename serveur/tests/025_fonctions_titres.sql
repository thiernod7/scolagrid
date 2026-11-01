-- Test de la migration 025 : une personne cumule deux titres de direction.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset

begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.personnel (id, organisation_id, site_id, nom_complet)
  values ('60000000-0000-0000-0000-000000000251', :'org_a', :'site_1', 'Mamadou Bah');
insert into public.affectations (organisation_id, personnel_id, site_id, fonction, libelle) values
  (:'org_a', '60000000-0000-0000-0000-000000000251', :'site_1', 'directeur', 'Principal'),
  (:'org_a', '60000000-0000-0000-0000-000000000251', :'site_1', 'directeur', 'Directeur général'),
  (:'org_a', '60000000-0000-0000-0000-000000000251', :'site_1', 'enseignant', null);
do $$ begin
  begin
    insert into public.affectations (organisation_id, personnel_id, site_id, fonction, libelle)
      values ((select organisation_id from public.personnel where id = '60000000-0000-0000-0000-000000000251'),
              '60000000-0000-0000-0000-000000000251',
              (select site_id from public.personnel where id = '60000000-0000-0000-0000-000000000251'), 'directeur', 'Principal');
    raise exception 'Le même titre deux fois';
  exception when unique_violation then null;
  end;
end $$;
commit;
do $$ begin
  assert (select count(*) from public.affectations where personnel_id = '60000000-0000-0000-0000-000000000251') = 3, 'Trois fonctions cumulées';
end $$;
delete from public.personnel where id = '60000000-0000-0000-0000-000000000251';
\echo 'Test 025 (titres) : tout est conforme.'
