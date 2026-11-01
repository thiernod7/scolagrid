-- Test de la migration 011 : réductions.
-- A : fondateur. D : directeur du site 1. S : secrétaire (encaisse). G : enseignant.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select id as classe_c from public.classes where organisation_id = :'org_a' and nom = '7ème C' \gset

-- Deux enfants payés par le même oncle
insert into public.eleves (id, organisation_id, matricule, site_origine_id, site_id, nom, prenoms) values
  ('e0000000-0000-0000-0000-000000000003', :'org_a', 'ALPHA-DONKA-2026-A003', :'site_1', :'site_1', 'SOW', 'Ibrahima'),
  ('e0000000-0000-0000-0000-000000000004', :'org_a', 'ALPHA-DONKA-2026-A004', :'site_1', :'site_1', 'SOW', 'Mariama');
insert into public.contacts (id, organisation_id, nom_complet, telephone)
  values ('c0000000-0000-0000-0000-000000000009', :'org_a', 'Oncle Sow', '+224620909090');
insert into public.eleves_contacts (organisation_id, eleve_id, contact_id, lien, tuteur_principal, responsable_financier) values
  (:'org_a', 'e0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000009', 'oncle', true, true),
  (:'org_a', 'e0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000009', 'oncle', true, true);
insert into public.inscriptions (id, organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission) values
  ('10000000-0000-0000-0000-000000000003', :'org_a', 'e0000000-0000-0000-0000-000000000003', :'annee', :'site_1', :'classe_c', 'nouvelle'),
  ('10000000-0000-0000-0000-000000000004', :'org_a', 'e0000000-0000-0000-0000-000000000004', :'annee', :'site_1', :'classe_c', 'nouvelle');

-- A définit les règles : fratrie 2 enfants -10 %, orphelin -100 % sur l'inscription, paiement annuel -5 %
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.regles_reduction (id, organisation_id, type, libelle, pourcentage, valeur, portee, nb_enfants) values
  ('a0000000-0000-0000-0000-000000000001', :'org_a', 'fratrie', '2 enfants', true, 10, 'scolarite', 2),
  ('a0000000-0000-0000-0000-000000000002', :'org_a', 'personnalisee', 'Orphelin', true, 100, 'inscription', null),
  ('a0000000-0000-0000-0000-000000000003', :'org_a', 'paiement_annuel', 'Année payée d''un coup', true, 5, 'scolarite', null);
do $$ begin
  begin
    insert into public.regles_reduction (organisation_id, type, libelle, valeur, portee, nb_enfants)
      values ((select id from public.organisations limit 1), 'fratrie', 'Mauvaise portée', 10, 'tous', 2);
    raise exception 'Une fratrie sur tous les frais a été acceptée';
  exception when check_violation then null;
  end;
end $$;
commit;

do $$ begin
  assert scolagrid.enfants_du_payeur('10000000-0000-0000-0000-000000000003') = 2, 'Deux enfants pour le même payeur';
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000003', 'scolarite', 750000) = 75000, 'Fratrie : -10 % sur la scolarité';
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000003', 'inscription', 150000) = 0, 'Fratrie : rien sur l''inscription';
end $$;

-- G (enseignant) n'attribue rien ; S (caisse) attribue le paiement annuel mais pas une bourse
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  begin
    insert into public.reductions_eleves (organisation_id, inscription_id, regle_id, motif)
      values ((select organisation_id from public.inscriptions limit 1), '10000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', 'Essai');
    raise exception 'Un enseignant a attribué une réduction';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.reductions_eleves (organisation_id, inscription_id, regle_id)
  values (:'org_a', '10000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000003');
do $$ begin
  begin
    insert into public.reductions_eleves (organisation_id, inscription_id, regle_id, motif)
      values ((select organisation_id from public.inscriptions limit 1), '10000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000002', 'Essai');
    raise exception 'La caisse a attribué une bourse';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- Sans cumul : la fratrie passe avant le paiement annuel (Mariama garde -10 %)
do $$ begin
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000004', 'scolarite', 750000) = 75000, 'Sans cumul : fratrie seule';
end $$;

-- D accorde « Orphelin » à Ibrahima : sans cumul, la fratrie reste prioritaire, il reste en attente
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.reductions_eleves (organisation_id, inscription_id, regle_id, motif)
  values (:'org_a', '10000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', 'Père décédé');
commit;
do $$ begin
  assert (select accorde_par from public.reductions_eleves where motif = 'Père décédé') = '44444444-4444-4444-4444-444444444444', 'Qui a accordé';
  assert (select statut from public.inscriptions where id = '10000000-0000-0000-0000-000000000003') = 'en_attente', 'Sans cumul, l''orphelin paie l''inscription';
end $$;

-- A autorise le cumul (plafond 100 %) : l'inscription d'Ibrahima est couverte, il devient actif
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
update public.organisations set reductions_cumul = true, reductions_plafond = 100;
commit;
update public.reductions_eleves set motif = 'Père décédé (cumul)' where motif = 'Père décédé';
do $$ begin
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000004', 'scolarite', 750000) = 112500, 'Cumul : 10 % + 5 %';
  assert (select statut from public.inscriptions where id = '10000000-0000-0000-0000-000000000003') = 'actif', 'Inscription couverte : actif d''office';
end $$;

-- Plafond à 12 % : la réduction cumulée est limitée
update public.organisations set reductions_plafond = 12 where id = :'org_a';
do $$ begin
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000004', 'scolarite', 750000) = 90000, 'Plafond de 12 %';
end $$;

\echo 'Test 011 : tout est conforme.'
