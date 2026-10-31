-- Test de la migration 007, joué après les tests précédents.
-- A : fondateur. S : secrétaire du site 1 (droit d'inscrire par défaut).
-- G : enseignant du site 2. B : autre école.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as site_2 from public.sites where organisation_id = :'org_a' and nom = 'Site de Ratoma' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select id as classe_b from public.classes where organisation_id = :'org_a' and nom = '7ème B' \gset
select id as classe_a2 from public.classes where organisation_id = :'org_a' and nom = '7ème A' \gset
select niveau_id as niveau from public.classes where id = :'classe_b' \gset
select set_config('test.org', :'org_a', false), set_config('test.site_1', :'site_1', false),
       set_config('test.site_2', :'site_2', false), set_config('test.annee', :'annee', false),
       set_config('test.classe_b', :'classe_b', false), set_config('test.classe_a2', :'classe_a2', false);

-- S : secrétaire du site 1
insert into auth.users (id, aud, role) values (:'s', 'authenticated', 'authenticated');
insert into public.personnel (organisation_id, site_id, nom_complet, user_id) values (:'org_a', :'site_1', 'Aïssatou Barry', :'s')
  returning id as fiche_s \gset
insert into public.affectations (organisation_id, personnel_id, site_id, fonction) values (:'org_a', :'fiche_s', :'site_1', 'secretaire');

-- A ouvre une deuxième classe de 7ème sur le site 1
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom, capacite)
  values (:'org_a', :'site_1', :'annee', :'niveau', '7ème C', 40) returning id as classe_c \gset
commit;
select set_config('test.classe_c', :'classe_c', false);

-- S inscrit un élève : fiche, parent (tuteur et payeur), inscription
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.eleves (id, organisation_id, matricule, site_origine_id, site_id, nom, prenoms, sexe, date_naissance, cree_par)
  values ('e0000000-0000-0000-0000-000000000001', :'org_a', 'ALPHA-DONKA-2026-A001', :'site_1', :'site_1', 'DIALLO', 'Amadou', 'M', '2014-03-15', :'b');
insert into public.contacts (id, organisation_id, nom_complet, telephone)
  values ('c0000000-0000-0000-0000-000000000001', :'org_a', 'Mamadou Diallo', '+224620101010');
insert into public.eleves_contacts (organisation_id, eleve_id, contact_id, lien, tuteur_principal, responsable_financier)
  values (:'org_a', 'e0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'pere', true, true);
insert into public.inscriptions (id, organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission)
  values ('10000000-0000-0000-0000-000000000001', :'org_a', 'e0000000-0000-0000-0000-000000000001', :'annee', :'site_1', :'classe_b', 'nouvelle');
do $$ begin
  assert (select cree_par from public.eleves) = '88888888-8888-8888-8888-888888888888', 'L''auteur de la fiche est celui qui est connecté';
  assert (select statut from public.inscriptions) = 'en_attente', 'Une inscription démarre « en attente »';
  assert (select count(*) from public.historique_eleves where evenement = 'inscription') = 1, 'L''inscription est historisée';
  -- Pas sur le site 2
  begin
    insert into public.eleves (organisation_id, matricule, site_origine_id, site_id, nom, prenoms)
      values (current_setting('test.org')::uuid, 'ALPHA-DONKA-2026-A002', current_setting('test.site_2')::uuid,
              current_setting('test.site_2')::uuid, 'SOW', 'Ibrahima');
    raise exception 'S a inscrit sur le site 2';
  exception when insufficient_privilege then null;
  end;
  -- Matricule unique
  begin
    insert into public.eleves (organisation_id, matricule, site_origine_id, site_id, nom, prenoms)
      values (current_setting('test.org')::uuid, 'ALPHA-DONKA-2026-A001', current_setting('test.site_1')::uuid,
              current_setting('test.site_1')::uuid, 'BAH', 'Fanta');
    raise exception 'Deux élèves avec le même matricule';
  exception when unique_violation then null;
  end;
  -- Un seul tuteur principal
  begin
    insert into public.contacts (id, organisation_id, nom_complet, telephone)
      values ('c0000000-0000-0000-0000-000000000002', current_setting('test.org')::uuid, 'Kadiatou Diallo', '+224620202020');
    insert into public.eleves_contacts (organisation_id, eleve_id, contact_id, lien, tuteur_principal)
      values (current_setting('test.org')::uuid, 'e0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', 'mere', true);
    raise exception 'Deux tuteurs principaux';
  exception when unique_violation then null;
  end;
  -- Une seule inscription par année
  begin
    insert into public.inscriptions (organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission)
      values (current_setting('test.org')::uuid, 'e0000000-0000-0000-0000-000000000001', current_setting('test.annee')::uuid,
              current_setting('test.site_1')::uuid, current_setting('test.classe_c')::uuid, 'nouvelle');
    raise exception 'Deux inscriptions la même année';
  exception when unique_violation then null;
  end;
  -- Classe d'un autre site
  begin
    update public.inscriptions set classe_id = current_setting('test.classe_a2')::uuid;
    raise exception 'Inscription dans une classe d''un autre site';
  exception when check_violation then null;
  end;
end $$;
-- Changement de classe, puis tentative de changer le matricule (ignorée)
update public.inscriptions set classe_id = :'classe_c';
update public.eleves set matricule = 'ALPHA-DONKA-2026-Z999', prenoms = 'Amadou Oury';
commit;
do $$ begin
  assert (select count(*) from public.historique_eleves where evenement = 'mutation') = 1, 'Le changement de classe est historisé';
  assert (select matricule from public.eleves where nom = 'DIALLO') = 'ALPHA-DONKA-2026-A001', 'Le matricule ne change jamais';
  assert (select prenoms from public.eleves where nom = 'DIALLO') = 'Amadou Oury', 'Le prénom se corrige';
end $$;

-- Annulation : date de sortie et historique
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
update public.inscriptions set statut = 'annule', motif = 'Départ à l''étranger';
commit;
do $$ begin
  assert (select date_sortie from public.inscriptions) = current_date, 'La date de sortie est posée';
  assert (select count(*) from public.historique_eleves where evenement = 'statut' and nouveau_statut = 'annule') = 1, 'L''annulation est historisée';
end $$;

-- G, enseignant : voit l'élève, pas les téléphones des parents ; n'inscrit pas
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.eleves) = 1, 'G voit les élèves de son école';
  assert (select count(*) from public.contacts) = 0, 'G ne voit pas les contacts des familles';
  assert (select count(*) from public.eleves_contacts) = 0, 'G ne voit pas les liens familiaux';
  begin
    insert into public.eleves (organisation_id, matricule, site_origine_id, site_id, nom, prenoms)
      values (current_setting('test.org')::uuid, 'ALPHA-RATOMA-2026-C001', current_setting('test.site_2')::uuid,
              current_setting('test.site_2')::uuid, 'CAMARA', 'Kadiatou');
    raise exception 'Un enseignant a inscrit un élève';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- B ne voit rien
begin;
select pg_temp.connecte(:'b');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.eleves) = 0, 'B ne voit aucun élève de A';
  assert (select count(*) from public.inscriptions) = 0, 'B ne voit aucune inscription de A';
  assert (select count(*) from public.historique_eleves) = 0, 'B ne voit aucun historique de A';
end $$;
commit;

\echo 'Test 007 : tout est conforme.'
