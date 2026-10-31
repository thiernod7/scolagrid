-- Test de la migration 006, joué après les tests précédents.
-- A : fondateur. B : autre école. D : directeur du site 1 de A.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set d '44444444-4444-4444-4444-444444444444'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select set_config('test.org', :'org_a', false), set_config('test.annee', :'annee', false);

-- A donne le sigle et l'identité de son école ; le code du site 1
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
update public.organisations set code = 'ALPHA', nom_officiel = 'Groupe scolaire Alpha', quartier = 'Donka',
  telephone = '+224 620 00 00 00', responsable_nom = 'Mamadou Kaba', responsable_titre = 'Directeur général';
update public.sites set code = 'DONKA' where id = :'site_1';
-- Frais de scolarité en 3 tranches
insert into public.frais (organisation_id, annee_id, libelle, montant_gnf, periodicite, type_frais)
  values (:'org_a', :'annee', 'Scolarité', 750000, 'tranches', 'scolarite') returning id as frais \gset
insert into public.echeances (organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite) values
  (:'org_a', :'frais', 1, 'Tranche 1', 250000, '2026-12-31'),
  (:'org_a', :'frais', 2, 'Tranche 2', 250000, '2027-03-31'),
  (:'org_a', :'frais', 3, 'Tranche 3', 250000, '2027-06-30');
commit;
select set_config('test.frais', :'frais', false);
do $$ begin
  assert (select code from public.organisations where id = current_setting('test.org')::uuid) = 'ALPHA', 'Le sigle doit être enregistré';
  assert (select count(*) from public.echeances) = 3, 'Les 3 tranches doivent exister';
end $$;

-- Le sigle et le code du site ne changent plus
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
do $$ begin
  begin
    update public.organisations set code = 'BETA' where id = current_setting('test.org')::uuid;
    raise exception 'Le sigle a pu être modifié';
  exception when check_violation then null;
  end;
  begin
    update public.sites set code = 'KALOUM' where code = 'DONKA';
    raise exception 'Le code du site a pu être modifié';
  exception when check_violation then null;
  end;
end $$;
commit;

-- Le sigle est unique sur tout Scolagrid
begin;
select pg_temp.connecte(:'b');
set local role authenticated;
do $$ begin
  begin
    update public.organisations set code = 'ALPHA';
    raise exception 'Deux écoles ont le même sigle';
  exception when unique_violation then null;
  end;
  assert (select count(*) from public.echeances) = 0, 'B ne voit pas les échéances de A';
end $$;
commit;

-- D, directeur du site 1 : ne touche pas aux tranches des frais du groupe
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.echeances) = 3, 'D voit les échéances';
  begin
    insert into public.echeances (organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite)
      values (current_setting('test.org')::uuid, current_setting('test.frais')::uuid, 4, 'Tranche 4', 1, '2027-07-01');
    raise exception 'D a modifié les tranches du groupe';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

\echo 'Test 006 : tout est conforme.'
