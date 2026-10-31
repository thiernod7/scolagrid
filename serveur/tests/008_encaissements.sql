-- Test de la migration 008, joué après les tests précédents.
-- S : secrétaire du site 1 (inscrit et encaisse). D : directeur du site 1
-- (peut annuler les reçus). G : enseignant. B : autre école.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
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
-- Les frais créés avant le typage : on précise que « Inscription » en est un.
update public.frais set type_frais = 'inscription' where organisation_id = :'org_a' and libelle = 'Inscription';
select id as frais_ins from public.frais where organisation_id = :'org_a' and libelle = 'Inscription' \gset
select id as frais_sco from public.frais where organisation_id = :'org_a' and libelle = 'Scolarité' \gset
select set_config('test.org', :'org_a', false), set_config('test.site_1', :'site_1', false),
       set_config('test.annee', :'annee', false), set_config('test.frais_ins', :'frais_ins', false);

-- S inscrit Fanta, puis encaisse 100 000 sur les 150 000 de l'inscription
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.eleves (id, organisation_id, matricule, site_origine_id, site_id, nom, prenoms)
  values ('e0000000-0000-0000-0000-000000000002', :'org_a', 'ALPHA-DONKA-2026-A002', :'site_1', :'site_1', 'BAH', 'Fanta');
insert into public.inscriptions (id, organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission)
  values ('10000000-0000-0000-0000-000000000002', :'org_a', 'e0000000-0000-0000-0000-000000000002', :'annee', :'site_1', :'classe_c', 'nouvelle');
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, carnet, feuille, payeur_nom, mode, total_gnf, date_effective, encaisse_par, statut)
  values ('20000000-0000-0000-0000-000000000001', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0001', 'Vert 1', '001452',
          'Mamadou Bah', 'especes', 100000, '2026-10-05', :'a', 'annule');
insert into public.lignes_encaissement (organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf)
  values (:'org_a', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002',
          'e0000000-0000-0000-0000-000000000002', :'frais_ins', 100000);
do $$ begin
  assert (select encaisse_par from public.encaissements) = '88888888-8888-8888-8888-888888888888', 'L''encaisseur est celui qui est connecté';
  assert (select statut from public.encaissements) = 'valide', 'Un reçu naît valide';
  assert (select statut from public.inscriptions where eleve_id = 'e0000000-0000-0000-0000-000000000002') = 'en_attente',
         'Inscription pas encore payée en entier';
end $$;
-- Le solde de l'inscription, plus une partie de la scolarité : l'élève devient actif
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, carnet, feuille, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000000002', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0002', 'Vert 1', '001453',
          'Mamadou Bah', 'orange_money', 150000, '2026-10-06');
insert into public.lignes_encaissement (organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf) values
  (:'org_a', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000002', :'frais_ins', 50000),
  (:'org_a', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000002', :'frais_sco', 100000);
do $$ begin
  assert (select statut from public.inscriptions where eleve_id = 'e0000000-0000-0000-0000-000000000002') = 'actif',
         'Inscription payée : élève actif';
  assert (select date_actif from public.inscriptions where eleve_id = 'e0000000-0000-0000-0000-000000000002') = '2026-10-05',
         'Date d''activation : premier paiement';
  -- Une feuille du carnet ne sert qu'une fois
  begin
    insert into public.encaissements (organisation_id, site_id, annee_id, numero, carnet, feuille, payeur_nom, mode, total_gnf)
      values (current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, current_setting('test.annee')::uuid,
              'REC-ALPHA-DONKA-2026-A0003', 'Vert 1', '001452', 'Quelqu''un', 'especes', 1000);
    raise exception 'Une feuille du carnet a servi deux fois';
  exception when unique_violation then null;
  end;
  -- Une ligne ne se modifie pas
  begin
    update public.lignes_encaissement set montant_gnf = 1;
    raise exception 'Une ligne de reçu a été modifiée';
  exception when insufficient_privilege then null;
  end;
end $$;
-- Le montant d'un reçu ne change pas ; un chèque attend sa confirmation
update public.encaissements set total_gnf = 1, payeur_nom = 'Autre' where numero = 'REC-ALPHA-DONKA-2026-A0001';
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, reference, total_gnf, confirmation)
  values (:'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0004', 'Mamadou Bah', 'cheque', 'CHQ 1234', 5000, 'confirme');
-- S annule son propre reçu du jour
update public.encaissements set statut = 'annule', motif_annulation = 'Mauvais montant' where numero = 'REC-ALPHA-DONKA-2026-A0004';
commit;
do $$ begin
  assert (select total_gnf from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0001') = 100000, 'Le montant du reçu est figé';
  assert (select confirmation from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0004') = 'en_attente', 'Un chèque attend';
  assert (select statut = 'annule' and annule_par = '88888888-8888-8888-8888-888888888888'
          from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0004'), 'L''encaisseur annule son reçu du jour';
end $$;

-- Au-delà de 24 h, S ne peut plus annuler ; D (droit annuler_recu) le peut
alter table public.encaissements disable trigger encaissement_protege;
update public.encaissements set created_at = now() - interval '2 days' where numero = 'REC-ALPHA-DONKA-2026-A0001';
alter table public.encaissements enable trigger encaissement_protege;
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  begin
    update public.encaissements set statut = 'annule', motif_annulation = 'Erreur' where numero = 'REC-ALPHA-DONKA-2026-A0001';
    raise exception 'S a annulé un reçu de plus de 24 h';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.encaissements set statut = 'annule', motif_annulation = 'Émis au mauvais élève' where numero = 'REC-ALPHA-DONKA-2026-A0001';
commit;
do $$ begin
  assert (select statut from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0001') = 'annule', 'D annule un ancien reçu';
end $$;

-- G, enseignant : ne voit pas la caisse et n'encaisse pas
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.encaissements) = 0, 'G ne voit pas les reçus';
  assert (select count(*) from public.lignes_encaissement) = 0, 'G ne voit pas les lignes';
  begin
    insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf)
      values (current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, current_setting('test.annee')::uuid,
              'REC-ALPHA-DONKA-2026-C0001', 'X Y', 'especes', 1000);
    raise exception 'Un enseignant a encaissé';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- B ne voit rien
begin;
select pg_temp.connecte(:'b');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.encaissements) = 0, 'B ne voit aucun reçu de A';
end $$;
commit;

\echo 'Test 008 : tout est conforme.'
