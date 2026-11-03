-- Test de la migration 030 : prénom(s) et nom séparés (personnel, parents, création d'espace).
\set ON_ERROR_STOP on
\set f '30303030-3030-3030-3030-303030303030'
begin;
insert into auth.users (id, aud, role, phone) values (:'f', 'authenticated', 'authenticated', '224620000030');
select set_config('request.jwt.claims', json_build_object('sub', :'f', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('request.jwt.claim.sub', :'f', true);
select public.creer_espace_ecole(nom_groupe => 'École 030', ville => 'Labé', nom_site => 'Site 030',
  nom_complet => 'Mamadou Saliou DIALLO', prenoms => 'Mamadou Saliou', nom => 'Diallo') as org \gset
select set_config('test.org', :'org', false);
do $$ begin
  assert (select prenoms || '|' || nom || '|' || nom_complet from public.personnel where organisation_id = current_setting('test.org')::uuid)
    = 'Mamadou Saliou|DIALLO|Mamadou Saliou DIALLO', 'Fiche du fondateur avec prénom et nom';
end $$;
-- Ancien appel à quatre paramètres : toujours accepté.
select public.creer_espace_ecole('École 030 bis', 'Labé', 'Site', 'Fondateur Bis') is not null as ok_ancien_appel;
reset role;
do $$ begin
  begin
    insert into public.contacts (organisation_id, nom_complet, prenoms, nom)
      values (current_setting('test.org')::uuid, 'XX', '', 'YY');
    raise exception 'ÉCHEC : prénom vide accepté';
  exception when check_violation then null;
  end;
end $$;
select 'Test 030 : tout est conforme.';
rollback;
