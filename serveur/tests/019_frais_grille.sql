-- Test de la migration 019 : calendrier, grille figée, modes « sous réserve », frais le plus précis.
-- A : fondateur. S : secrétaire du site 1 (encaisse).

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select id as frais_ins from public.frais where organisation_id = :'org_a' and libelle = 'Inscription' \gset
select set_config('test.org', :'org_a', false), set_config('test.annee', :'annee', false),
       set_config('test.site_1', :'site_1', false), set_config('test.frais_ins', :'frais_ins', false);

-- Calendrier : le fondateur le règle, la secrétaire non.
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.tranches_annee (organisation_id, annee_id, ordre, libelle, date_limite, part) values
  (:'org_a', :'annee', 1, 'Tranche 1', '2026-10-15', 40), (:'org_a', :'annee', 2, 'Tranche 2', '2027-01-15', 30),
  (:'org_a', :'annee', 3, 'Tranche 3', '2027-04-15', 30);
update public.annees_scolaires set periodicite = 'tranches', nb_mois = 9 where id = :'annee';
commit;
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.tranches_annee) = 3, 'La secrétaire voit le calendrier';
  begin
    insert into public.tranches_annee (organisation_id, annee_id, ordre, libelle, date_limite, part)
      values (current_setting('test.org')::uuid, current_setting('test.annee')::uuid, 4, 'X', '2027-05-01', 10);
    raise exception 'La secrétaire a changé le calendrier';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- Grille figée : un frais déjà payé ne change qu'avec un motif, et la correction est gardée.
do $$ begin
  begin
    update public.frais set montant_gnf = montant_gnf + 10000 where id = current_setting('test.frais_ins')::uuid;
    raise exception 'Un frais payé a changé sans motif';
  exception when check_violation then null;
  end;
end $$;
update public.frais set montant_gnf = montant_gnf + 10000, motif_correction = 'Erreur de saisie' where id = :'frais_ins';
do $$ begin
  assert (select count(*) from public.historique_frais where frais_id = current_setting('test.frais_ins')::uuid) = 1, 'Correction gardée';
  assert (select nouveau_gnf - ancien_gnf from public.historique_frais) = 10000, 'Ancien et nouveau montants';
end $$;
update public.frais set montant_gnf = montant_gnf - 10000, motif_correction = 'Retour au montant initial' where id = :'frais_ins';

-- Modes « sous réserve » : Orange Money ajouté par l'école.
update public.organisations set modes_sous_reserve = 'cheque,virement,orange_money' where id = :'org_a';
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, reference, total_gnf)
  values ('20000000-0000-0000-0000-000000000099', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0099', 'Fatou Camara',
          'orange_money', 'OM 556677', 1000);
commit;
do $$ begin
  assert (select confirmation from public.encaissements where id = '20000000-0000-0000-0000-000000000099') = 'en_attente',
    'Orange Money sous réserve quand l''école le demande';
end $$;
do $$ begin
  begin
    update public.organisations set modes_sous_reserve = 'cheque,carte' where id = current_setting('test.org')::uuid;
    raise exception 'Mode inconnu accepté';
  exception when check_violation then null;
  end;
end $$;
update public.organisations set modes_sous_reserve = 'cheque,virement' where id = :'org_a';
delete from public.tranches_annee where annee_id = :'annee';
\echo 'Test 019 : tout est conforme.'
