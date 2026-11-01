-- Les tables où l'on crée sans modifier (lignes de reçu, clôtures, impressions)
-- acceptent l'envoi des postes « créer, ou ne rien faire si c'est déjà là »
-- (insert … on conflict do nothing), et refusent toujours la modification.
-- S : secrétaire du site 1 (encaisse).

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
select id as frais_sco from public.frais where organisation_id = :'org_a' and libelle = 'Scolarité' \gset

begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000000251', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0251', 'Essai', 'especes', 1000, '2026-11-05')
  on conflict (id) do nothing;
-- Envoyée deux fois (réseau coupé) : la deuxième ne fait rien.
insert into public.lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf)
  values ('30000000-0000-0000-0000-000000000251', :'org_a', '20000000-0000-0000-0000-000000000251',
          '10000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000003', :'frais_sco', 1000)
  on conflict (id) do nothing;
insert into public.lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf)
  values ('30000000-0000-0000-0000-000000000251', :'org_a', '20000000-0000-0000-0000-000000000251',
          '10000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000003', :'frais_sco', 999999)
  on conflict (id) do nothing;
insert into public.clotures_caisse (id, organisation_id, site_id, encaisse_par, jour, compte_especes)
  values ('50000000-0000-0000-0000-000000000251', :'org_a', :'site_1', :'s', '2026-11-05', 1000)
  on conflict (id) do nothing;
do $$ begin
  begin
    insert into public.lignes_encaissement (id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, montant_gnf)
      select id, organisation_id, encaissement_id, inscription_id, eleve_id, frais_id, 5 from public.lignes_encaissement
      where id = '30000000-0000-0000-0000-000000000251'
      on conflict (id) do update set montant_gnf = excluded.montant_gnf;
    raise exception 'Une ligne de reçu a été modifiée';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
do $$ begin
  assert (select montant_gnf from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000251') = 1000, 'Ligne enregistrée une fois';
  assert (select count(*) from public.clotures_caisse where id = '50000000-0000-0000-0000-000000000251') = 1, 'Clôture enregistrée';
end $$;

delete from public.clotures_caisse where id = '50000000-0000-0000-0000-000000000251';
delete from public.lignes_encaissement where id = '30000000-0000-0000-0000-000000000251';
delete from public.encaissements where id = '20000000-0000-0000-0000-000000000251';
\echo 'Test 025 : tout est conforme.'
