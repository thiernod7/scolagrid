-- Test de la migration 023 : enfant du personnel, motif et durée, remboursement oral.
-- A : fondateur. D : directeur du site 1 (valide). S : secrétaire du site 1 (encaisse).

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select reductions_cumul as cumul_avant, reductions_plafond as plafond_avant from public.organisations where id = :'org_a' \gset
select id as fiche_d from public.personnel where user_id = :'d' \gset
select set_config('test.org', :'org_a', false), set_config('test.fiche_d', :'fiche_d', false);

-- Le fondateur crée « Enfant du personnel » (sur tous les frais) et une bourse.
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.regles_reduction (id, organisation_id, type, libelle, pourcentage, valeur, portee) values
  ('a0000000-0000-0000-0000-000000000231', :'org_a', 'personnel', 'Enfant du personnel', true, 50, 'tous'),
  ('a0000000-0000-0000-0000-000000000232', :'org_a', 'personnalisee', 'Bourse 20 %', true, 20, 'scolarite');
commit;

-- Le directeur : motif et parent obligatoires.
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  begin
    insert into public.reductions_eleves (organisation_id, inscription_id, regle_id)
      values (current_setting('test.org')::uuid, '10000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000232');
    raise exception 'Bourse sans motif acceptée';
  exception when check_violation then null;
  end;
  begin
    insert into public.reductions_eleves (organisation_id, inscription_id, regle_id, motif)
      values (current_setting('test.org')::uuid, '10000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000231', 'Fille du surveillant');
    raise exception 'Enfant du personnel sans parent accepté';
  exception when check_violation then null;
  end;
end $$;
insert into public.reductions_eleves (id, organisation_id, inscription_id, regle_id, motif, personnel_id, duree_annees, annee_rang)
  values ('b0000000-0000-0000-0000-000000000231', :'org_a', '10000000-0000-0000-0000-000000000004',
          'a0000000-0000-0000-0000-000000000231', 'Fille du directeur', :'fiche_d', 3, 5);
insert into public.reductions_eleves (id, organisation_id, inscription_id, regle_id, motif)
  values ('b0000000-0000-0000-0000-000000000232', :'org_a', '10000000-0000-0000-0000-000000000004',
          'a0000000-0000-0000-0000-000000000232', 'Mérite');
commit;
do $$ begin
  assert (select annee_rang from public.reductions_eleves where id = 'b0000000-0000-0000-0000-000000000231') = 1,
    'Une nouvelle réduction commence à la première année';
end $$;

-- Priorité sans cumul : la fratrie d'abord ; avec cumul : tout s'additionne.
update public.organisations set reductions_cumul = false where id = :'org_a';
do $$ begin
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000004', 'scolarite', 750000) = 75000, 'Sans cumul : fratrie seule';
end $$;
update public.organisations set reductions_cumul = true, reductions_plafond = 100 where id = :'org_a';
do $$ begin
  -- 10 % fratrie + 50 % personnel + 5 % paiement annuel + 20 % bourse
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000004', 'scolarite', 750000) = 637500, 'Cumul des quatre';
  assert scolagrid.reduction_frais('10000000-0000-0000-0000-000000000004', 'inscription', 100000) = 50000, 'Personnel sur l''inscription aussi';
end $$;

-- Reconduction : année 2 sur 3, la durée et le parent suivent ; une bourse d'un an ne se reconduit pas.
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.reductions_eleves (id, organisation_id, inscription_id, regle_id, motif, reconduite_de)
  values ('b0000000-0000-0000-0000-000000000233', :'org_a', '10000000-0000-0000-0000-000000000003',
          'a0000000-0000-0000-0000-000000000231', 'Fille du directeur', 'b0000000-0000-0000-0000-000000000231');
do $$ begin
  begin
    insert into public.reductions_eleves (organisation_id, inscription_id, regle_id, motif, reconduite_de)
      values (current_setting('test.org')::uuid, '10000000-0000-0000-0000-000000000003',
              'a0000000-0000-0000-0000-000000000232', 'Mérite', 'b0000000-0000-0000-0000-000000000232');
    raise exception 'Bourse d''un an reconduite';
  exception when check_violation then null;
  end;
end $$;
commit;
do $$ begin
  assert (select annee_rang from public.reductions_eleves where id = 'b0000000-0000-0000-0000-000000000233') = 2, 'Deuxième année';
  assert (select duree_annees from public.reductions_eleves where id = 'b0000000-0000-0000-0000-000000000233') = 3, 'Sur trois ans';
  assert (select personnel_id from public.reductions_eleves where id = 'b0000000-0000-0000-0000-000000000233')
    = current_setting('test.fiche_d')::uuid, 'Le parent suit';
end $$;

-- Remboursement autorisé de vive voix par le directeur.
select remboursement_aucun as aucun_avant, remboursable_scolarite as sco_avant from public.organisations where id = :'org_a' \gset
update public.organisations set remboursement_aucun = false, remboursable_scolarite = true where id = :'org_a';
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  begin
    insert into public.remboursements (organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id,
                                       montant_gnf, beneficiaire, motif, autorisation_orale)
      select organisation_id, '00000000-0000-0000-0000-000000000000', id, encaissement_id, inscription_id, eleve_id, frais_id,
             5000, 'Oncle Sow', 'Départ', true
      from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000002';
    raise exception 'Autorisation orale sans nom acceptée';
  exception when check_violation then null;
  end;
end $$;
insert into public.remboursements (id, organisation_id, site_id, ligne_id, encaissement_id, inscription_id, eleve_id, frais_id,
                                   montant_gnf, beneficiaire, motif, autorisation_orale, autorise_oralement_par)
  select '40000000-0000-0000-0000-000000000231', organisation_id, '00000000-0000-0000-0000-000000000000', id, encaissement_id,
         inscription_id, eleve_id, frais_id, 5000, 'Oncle Sow', 'Départ urgent', true, :'fiche_d'
  from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000002';
update public.remboursements set statut = 'verse' where id = '40000000-0000-0000-0000-000000000231';
do $$ begin
  begin
    update public.remboursements set confirmation = 'confirmee' where id = '40000000-0000-0000-0000-000000000231';
    raise exception 'La caisse a confirmé elle-même';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
do $$ begin
  assert (select statut from public.remboursements where id = '40000000-0000-0000-0000-000000000231') = 'verse', 'Versé tout de suite';
  assert (select confirmation from public.remboursements where id = '40000000-0000-0000-0000-000000000231') = 'attendue', 'À confirmer';
  assert (select delai_confirmation_heures from public.organisations where id = current_setting('test.org')::uuid) = 48, '48 h';
end $$;
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  begin
    update public.remboursements set confirmation = 'contestee' where id = '40000000-0000-0000-0000-000000000231';
    raise exception 'Contestation sans motif acceptée';
  exception when check_violation then null;
  end;
end $$;
update public.remboursements set confirmation = 'confirmee', montant_gnf = 1 where id = '40000000-0000-0000-0000-000000000231';
commit;
do $$ begin
  assert (select confirme_par from public.remboursements where id = '40000000-0000-0000-0000-000000000231')
    = '44444444-4444-4444-4444-444444444444', 'Confirmé par D';
  assert (select montant_gnf from public.remboursements where id = '40000000-0000-0000-0000-000000000231') = 5000, 'Montant inchangé';
end $$;

-- Ménage.
delete from public.remboursements where id = '40000000-0000-0000-0000-000000000231';
delete from public.reductions_eleves where id in ('b0000000-0000-0000-0000-000000000233', 'b0000000-0000-0000-0000-000000000232',
                                                  'b0000000-0000-0000-0000-000000000231');
delete from public.regles_reduction where id in ('a0000000-0000-0000-0000-000000000231', 'a0000000-0000-0000-0000-000000000232');
update public.organisations set reductions_cumul = :'cumul_avant', reductions_plafond = :'plafond_avant',
  remboursement_aucun = :'aucun_avant', remboursable_scolarite = :'sco_avant' where id = :'org_a';
\echo 'Test 023 : tout est conforme.'
