-- Test de la migration 014 : remboursements.
-- S : secrétaire du site 1 (encaisse). D : directeur du site 1 (valide les remboursements).

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select set_config('test.site_1', (select id::text from public.sites where nom = 'Site de Kaloum'), false);
select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select id as frais_ins from public.frais where organisation_id = :'org_a' and libelle = 'Inscription' \gset
select id as frais_sco from public.frais where organisation_id = :'org_a' and libelle = 'Scolarité' \gset
-- Le plafond des réductions du test 011 ne gêne pas ici ; on repart sans cumul.
update public.organisations set reductions_cumul = false where id = :'org_a';

-- S encaisse le 03/11 en espèces : inscription 50 000 et scolarité 100 000 pour Ibrahima
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000000301', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0301', 'Oncle Sow', 'especes', 150000, '2026-11-03');
insert into public.lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf) values
  ('30000000-0000-0000-0000-000000000001', :'org_a', '20000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000003', :'frais_ins', 50000),
  ('30000000-0000-0000-0000-000000000002', :'org_a', '20000000-0000-0000-0000-000000000301', '10000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000003', :'frais_sco', 100000);
do $$ begin
  -- Inscription non remboursable (politique par défaut)
  begin
    insert into public.remboursements (organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, beneficiaire, motif)
      select organisation_id, current_setting('test.site_1', true)::uuid, id, encaissement_id, inscription_id, eleve_id, frais_id, 10000, 'Oncle Sow', 'Départ'
      from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000001';
    raise exception 'Inscription remboursée malgré la politique';
  exception when check_violation then null;
  end;
  -- Plus que ce qui a été payé
  begin
    insert into public.remboursements (organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, beneficiaire, motif)
      select organisation_id, current_setting('test.site_1', true)::uuid, id, encaissement_id, inscription_id, eleve_id, frais_id, 120000, 'Oncle Sow', 'Départ'
      from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000002';
    raise exception 'Remboursement supérieur au payé accepté';
  exception when check_violation then null;
  end;
end $$;
insert into public.remboursements (id, organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, beneficiaire, motif)
  values ('40000000-0000-0000-0000-000000000001', :'org_a', :'site_1', '30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000301',
          '10000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000003', :'frais_sco', 60000, 'Oncle Sow', 'Départ à Kindia');
do $$ begin
  assert (select statut from public.remboursements) = 'demande', 'Une demande démarre « demande »';
  assert (select demande_par from public.remboursements) = '88888888-8888-8888-8888-888888888888', 'Demandé par S';
  -- S n'autorise pas lui-même
  begin
    update public.remboursements set statut = 'autorise';
    raise exception 'S a autorisé un remboursement';
  exception when insufficient_privilege then null;
  end;
  -- Pas de versement avant autorisation
  begin
    update public.remboursements set statut = 'verse';
    raise exception 'Versement sans autorisation';
  exception when check_violation then null;
  end;
end $$;
commit;

-- D autorise ; S verse le même jour, en espèces, contre décharge
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.remboursements set statut = 'autorise' where id = '40000000-0000-0000-0000-000000000001';
commit;
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
update public.remboursements set statut = 'verse', verse_le = '2026-11-03', decharge = 'Décharges n° 3 · 0007'
  where id = '40000000-0000-0000-0000-000000000001';
do $$ begin
  -- Une deuxième demande ne peut pas dépasser le reste (100 000 - 60 000)
  begin
    insert into public.remboursements (organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, beneficiaire, motif)
      select organisation_id, current_setting('test.site_1', true)::uuid, id, encaissement_id, inscription_id, eleve_id, frais_id, 50000, 'Oncle Sow', 'Encore'
      from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000002';
    raise exception 'Deux remboursements dépassent le payé';
  exception when check_violation then null;
  end;
end $$;
-- Clôture du 03/11 : 150 000 encaissés - 60 000 remboursés = 90 000 attendus
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
  values (:'org_a', :'site_1', :'s', '2026-11-03', 90000);
commit;
do $$ begin
  assert (select statut = 'verse' and autorise_par = '44444444-4444-4444-4444-444444444444' and verse_par = '88888888-8888-8888-8888-888888888888'
          from public.remboursements where id = '40000000-0000-0000-0000-000000000001'), 'Circuit complet tracé';
  assert (select attendu_especes from public.clotures_caisse where jour = '2026-11-03') = 90000, 'Le remboursement sort de la caisse';
  assert (select ecart from public.clotures_caisse where jour = '2026-11-03') = 0, 'Sans écart';
end $$;

-- « Aucun remboursement » prime sur tout
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
update public.organisations set remboursement_aucun = true;
commit;
select set_config('test.site_1', :'site_1', false);
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  begin
    insert into public.remboursements (organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, beneficiaire, motif)
      select organisation_id, current_setting('test.site_1')::uuid, id, encaissement_id, inscription_id, eleve_id, frais_id, 1000, 'Oncle Sow', 'Essai'
      from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000002';
    raise exception 'Remboursement accepté malgré « aucun remboursement »';
  exception when check_violation then null;
  end;
end $$;
commit;

\echo 'Test 014 : tout est conforme.'
