-- Test de la migration 040 : répartition par tranche figée sur la ligne du reçu.
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
select id as frais_sco, montant_gnf as total_sco from public.frais where organisation_id = :'org_a' and libelle = 'Scolarité' \gset

begin;
update public.organisations set reductions_cumul = false where id = :'org_a';
-- Trois tranches pour la scolarité de test.
delete from public.echeances where frais_id = :'frais_sco';
insert into public.echeances (organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite) values
  (:'org_a', :'frais_sco', 1, '1re tranche', :total_sco / 3, '2026-10-15'),
  (:'org_a', :'frais_sco', 2, '2e tranche', :total_sco / 3, '2027-01-15'),
  (:'org_a', :'frais_sco', 3, '3e tranche', :total_sco - 2 * (:total_sco / 3), '2027-04-15');
select set_config('test.t1', (:total_sco / 3)::text, false);

select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000004001', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A4001', 'Oncle Sow', 'especes', 100000, '2026-11-03');

-- Une répartition fausse (somme ≠ montant) est refusée.
do $$ begin
  insert into public.lignes_encaissement (organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, imputation)
  select organisation_id, '20000000-0000-0000-0000-000000004001', '10000000-0000-0000-0000-000000000003',
         'e0000000-0000-0000-0000-000000000003', id, 100000, '[{"tranche": "1re tranche", "montant": 90000}]'
  from public.frais where libelle = 'Scolarité' and organisation_id = (select organisation_id from public.encaissements where id = '20000000-0000-0000-0000-000000004001');
  assert false, 'Répartition fausse acceptée';
exception when check_violation then null;
end $$;

-- Une juste est acceptée, et figée.
insert into public.lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf, imputation)
  values ('30000000-0000-0000-0000-000000004001', :'org_a', '20000000-0000-0000-0000-000000004001', '10000000-0000-0000-0000-000000000003',
          'e0000000-0000-0000-0000-000000000003', :'frais_sco', 100000,
          '[{"tranche": "1re tranche", "echeance": "2026-10-15", "montant": 100000}]');
do $$ begin
  update public.lignes_encaissement set imputation = '[{"tranche": "2e tranche", "montant": 100000}]'
   where id = '30000000-0000-0000-0000-000000004001';
  assert false, 'Répartition modifiée';
exception when insufficient_privilege then null;
end $$;

-- Un ancien reçu sans répartition (version précédente de l'app) : la reprise
-- le répartit, à cheval sur deux tranches.
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000004002', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A4002', 'Oncle Sow', 'especes', 300000, '2026-11-04');
insert into public.lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf)
  values ('30000000-0000-0000-0000-000000004002', :'org_a', '20000000-0000-0000-0000-000000004002', '10000000-0000-0000-0000-000000000003',
          'e0000000-0000-0000-0000-000000000003', :'frais_sco', 300000);
reset role;
select scolagrid.imputer_tranches();
do $$ declare imp jsonb; somme bigint; begin
  select imputation into imp from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000004002';
  assert imp is not null, 'Ancien reçu réparti';
  select sum((x->>'montant')::bigint) into somme from jsonb_array_elements(imp) x;
  assert somme = 300000, format('Somme répartie : %s', somme);
  -- La ligne déjà répartie (saisie avec sa répartition) ne bouge pas.
  assert (select imputation->0->>'tranche' from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000004001') = '1re tranche',
    'Répartition saisie conservée';
end $$;
rollback;
\echo '040 imputation : OK'
