-- Test de la migration 026 : postes à valider, clôtures complémentaires, tranches en mois.
-- D : directeur du site 1. S : secrétaire du site 1.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select set_config('test.org', :'org_a', false), set_config('test.site', :'site_1', false), set_config('test.annee', :'annee', false);

-- La secrétaire active un poste : il attend la direction et n'encaisse pas.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
select (public.activer_poste(:'org_a', :'site_1', 'Téléphone de la secrétaire') ->> 'id') as poste_s \gset
select set_config('test.poste_s', :'poste_s', false);
do $$ begin
  assert (select statut from public.postes where id = current_setting('test.poste_s')::uuid) = 'a_valider', 'Poste en attente';
  begin
    insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective, poste_id)
      values (current_setting('test.org')::uuid, current_setting('test.site')::uuid, current_setting('test.annee')::uuid,
              'REC-ALPHA-DONKA-2026-Z0001', 'Essai', 'especes', 1000, '2026-10-07', current_setting('test.poste_s')::uuid);
    raise exception 'Un poste en attente a encaissé';
  exception when insufficient_privilege then null;
  end;
  -- Elle ne se valide pas elle-même.
  update public.postes set statut = 'actif' where id = current_setting('test.poste_s')::uuid;
  assert (select statut from public.postes where id = current_setting('test.poste_s')::uuid) = 'a_valider', 'Pas d''auto-validation';
end $$;
commit;

-- Le directeur valide ; son propre poste est actif d'office.
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.postes set statut = 'actif' where id = :'poste_s';
select (public.activer_poste(:'org_a', :'site_1', 'PC du directeur') ->> 'statut') as statut_d \gset
commit;
do $$ begin
  assert (select statut from public.postes where id = current_setting('test.poste_s')::uuid) = 'actif', 'Validé par le directeur';
end $$;
select :'statut_d' = 'actif' as directeur_actif \gset
\if :directeur_actif
\else
  \echo 'Le poste du directeur devrait être actif'
  select 1/0;
\endif

-- Clôture, puis complément.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000000261', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-Z0261', 'Essai', 'especes', 1000, '2026-10-07');
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
  values (:'org_a', :'site_1', :'s', '2026-10-07', 1000);
insert into public.encaissements (id, organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values ('20000000-0000-0000-0000-000000000262', :'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-Z0262', 'Essai', 'especes', 500, '2026-10-07');
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
  values (:'org_a', :'site_1', :'s', '2026-10-07', 500);
do $$ begin
  begin
    insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
      values (current_setting('test.org')::uuid, current_setting('test.site')::uuid, '88888888-8888-8888-8888-888888888888', '2026-10-07', 0);
    raise exception 'Clôture sans rien de nouveau';
  exception when unique_violation then null;
  end;
end $$;
commit;
do $$ begin
  assert (select attendu_especes from public.clotures_caisse where jour = '2026-10-07' and rang = 1) = 1000, 'Première clôture : 1 000';
  assert (select attendu_especes from public.clotures_caisse where jour = '2026-10-07' and rang = 2) = 500, 'Complément : 500';
  assert (select nb_recus from public.clotures_caisse where jour = '2026-10-07' and rang = 2) = 1, 'Complément : un reçu';
  begin
    insert into public.tranches_annee (organisation_id, annee_id, ordre, libelle, date_limite, part, mois)
      values (current_setting('test.org')::uuid, current_setting('test.annee')::uuid, 20, 'Trop', '2027-01-31', 10, 13);
    raise exception 'Tranche de 13 mois acceptée';
  exception when check_violation then null;
  end;
end $$;

-- Ménage.
delete from public.clotures_caisse where jour = '2026-10-07';
delete from public.encaissements where id in ('20000000-0000-0000-0000-000000000261', '20000000-0000-0000-0000-000000000262');
delete from public.postes where nom in ('Téléphone de la secrétaire', 'PC du directeur');
\echo 'Test 026 : tout est conforme.'
