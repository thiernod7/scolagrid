-- Test de la migration 003, joué par GitHub sur une base jetable, après 002.
-- A : fondateur (créé par le test 002, deux sites). B : fondateur d'une autre école.
-- C : directeur du premier site de A uniquement.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set c '33333333-3333-3333-3333-333333333333'

insert into auth.users (id, aud, role, phone) values (:'c', 'authenticated', 'authenticated', '224620000003');

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as site_2 from public.sites where organisation_id = :'org_a' and nom = 'Site de Ratoma' \gset

-- B crée sa propre école
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'b', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('request.jwt.claim.sub', :'b', true);
set local role authenticated;
select public.creer_espace_ecole('École de B', 'Kindia', 'Site de B', 'Fondateur B') as org_b \gset
commit;
select id as site_b from public.sites where organisation_id = :'org_b' \gset

-- C devient directeur du site 1 de A (les invitations viendront à l'étape 3)
insert into public.rattachements (organisation_id, site_id, user_id, role) values (:'org_a', :'site_1', :'c', 'directeur');

-- A configure son école
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'a', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('request.jwt.claim.sub', :'a', true);
set local role authenticated;
insert into public.annees_scolaires (organisation_id, libelle, debut, fin, en_cours)
  values (:'org_a', '2026-2027', '2026-10-01', '2027-07-15', true) returning id as annee \gset
insert into public.niveaux (organisation_id, cycle, nom, ordre) values (:'org_a', 'college', '7ème', 7) returning id as niveau \gset
insert into public.matieres (organisation_id, niveau_id, nom, coefficient) values (:'org_a', :'niveau', 'Mathématiques', 3);
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom, salle) values (:'org_a', :'site_2', :'annee', :'niveau', '7ème A', 'Salle 1');
insert into public.frais (organisation_id, annee_id, libelle, montant_gnf, periodicite) values (:'org_a', :'annee', 'Inscription', 150000, 'unique');
do $$ begin
  assert (select count(*) from public.classes) = 1, 'A doit voir sa classe';
  assert (select count(*) from public.frais) = 1, 'A doit voir ses frais';
end $$;
-- Une seule année en cours
do $$ begin
  insert into public.annees_scolaires (organisation_id, libelle, debut, fin, en_cours)
    values ((select id from public.organisations limit 1), '2027-2028', '2027-10-01', '2028-07-15', true);
  raise exception 'Deux années en cours acceptées';
exception when unique_violation then null;
end $$;
commit;

-- Une classe de A ne peut pas être rattachée au site de B
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'a', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('request.jwt.claim.sub', :'a', true);
select set_config('test.site_b', :'site_b', true);
select set_config('test.annee', :'annee', true);
select set_config('test.niveau', :'niveau', true);
set local role authenticated;
do $$ begin
  insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom)
    values ((select id from public.organisations limit 1), current_setting('test.site_b')::uuid,
            current_setting('test.annee')::uuid, current_setting('test.niveau')::uuid, 'Classe égarée');
  raise exception 'Classe rattachée au site d''une autre école';
exception when foreign_key_violation then null;
end $$;
commit;

-- C, directeur du site 1 : gère les classes de son site, pas celles du site 2, ni les niveaux
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'c', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('request.jwt.claim.sub', :'c', true);
select set_config('test.site_1', :'site_1', true);
select set_config('test.site_2', :'site_2', true);
select set_config('test.annee', :'annee', true);
select set_config('test.niveau', :'niveau', true);
select set_config('test.org', :'org_a', true);
set local role authenticated;
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom) values (:'org_a', :'site_1', :'annee', :'niveau', '7ème B');
do $$ begin
  assert (select count(*) from public.classes) = 2, 'C doit voir les classes de son école';
  begin
    insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom)
      values (current_setting('test.org')::uuid, current_setting('test.site_2')::uuid,
              current_setting('test.annee')::uuid, current_setting('test.niveau')::uuid, '7ème C');
    raise exception 'C a pu créer une classe sur un autre site';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.niveaux (organisation_id, cycle, nom) values (current_setting('test.org')::uuid, 'lycee', '11ème');
    raise exception 'C a pu créer un niveau';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.frais (organisation_id, annee_id, libelle, montant_gnf)
      values (current_setting('test.org')::uuid, current_setting('test.annee')::uuid, 'Frais pour tout le groupe', 1000);
    raise exception 'C a pu créer des frais pour tout le groupe';
  exception when insufficient_privilege then null;
  end;
end $$;
-- Frais de son propre site : autorisés
insert into public.frais (organisation_id, annee_id, site_id, libelle, montant_gnf, periodicite)
  values (:'org_a', :'annee', :'site_1', 'Cantine', 50000, 'mensuel');
delete from public.classes where nom = '7ème A';   -- site 2 : ignoré par les règles
commit;
do $$ begin
  assert (select count(*) from public.classes where nom = '7ème A') = 1, 'C ne doit pas supprimer une classe du site 2';
end $$;

-- B ne voit rien de la configuration de A
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'b', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('request.jwt.claim.sub', :'b', true);
set local role authenticated;
do $$ begin
  assert (select count(*) from public.annees_scolaires) = 0, 'B ne doit voir aucune année de A';
  assert (select count(*) from public.classes) = 0, 'B ne doit voir aucune classe de A';
  assert (select count(*) from public.matieres) = 0, 'B ne doit voir aucune matière de A';
  assert (select count(*) from public.frais) = 0, 'B ne doit voir aucun frais de A';
end $$;
commit;

\echo 'Test 003 : tout est conforme.'
