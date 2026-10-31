-- Test de la migration 012 : clôture de caisse.
-- S : secrétaire du site 1 (encaisse). D : directeur du site 1 (annule les reçus). G : enseignant.

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
select set_config('test.org', :'org_a', false), set_config('test.site_1', :'site_1', false), set_config('test.annee', :'annee', false);

-- S encaisse le 02/11 : 100 000 en espèces, 50 000 par Orange Money
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective) values
  (:'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0101', 'Parent Un', 'especes', 100000, '2026-11-02'),
  (:'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0102', 'Parent Deux', 'orange_money', 50000, '2026-11-02');
do $$ begin
  -- Écart sans justification : refusé
  begin
    insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
      values (current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, auth.uid(), '2026-11-02', 90000);
    raise exception 'Écart non justifié accepté';
  exception when check_violation then null;
  end;
  -- Clôturer la caisse d'un autre : refusé
  begin
    insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
      values (current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, '44444444-4444-4444-4444-444444444444', '2026-11-02', 0);
    raise exception 'S a clôturé la caisse de D';
  exception when insufficient_privilege then null;
  end;
end $$;
-- Le client annonce un attendu faux : le serveur recalcule
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes, attendu_especes, justification)
  values (:'org_a', :'site_1', :'s', '2026-11-02', 90000, 1, 'Monnaie rendue en trop');
commit;
do $$ begin
  assert (select attendu_especes from public.clotures_caisse where jour = '2026-11-02') = 100000, 'Attendu recalculé : espèces seulement';
  assert (select ecart from public.clotures_caisse where jour = '2026-11-02') = -10000, 'Écart de -10 000';
  assert (select nb_recus from public.clotures_caisse where jour = '2026-11-02') = 2, 'Deux reçus';
  assert (select total_autres_modes from public.clotures_caisse where jour = '2026-11-02') = 50000, 'Orange Money à part';
end $$;

-- Journée close : pas de modification, pas d'annulation par S ; un reçu tardif est signalé
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  begin
    update public.clotures_caisse set compte_especes = 100000;
    raise exception 'Une clôture a été modifiée';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.encaissements set statut = 'annule', motif_annulation = 'Erreur' where numero = 'REC-ALPHA-DONKA-2026-A0101';
    raise exception 'S a annulé un reçu d''une journée close';
  exception when insufficient_privilege then null;
  end;
end $$;
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values (:'org_a', :'site_1', :'annee', 'REC-ALPHA-DONKA-2026-A0103', 'Parent Trois', 'especes', 20000, '2026-11-02');
commit;
do $$ begin
  assert (select apres_cloture from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0103'), 'Reçu après clôture signalé';
  assert not (select apres_cloture from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0101'), 'Reçu normal non signalé';
end $$;

-- D (droit annuler_recu) annule un reçu de la journée close
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.encaissements set statut = 'annule', motif_annulation = 'Mauvais élève' where numero = 'REC-ALPHA-DONKA-2026-A0101';
commit;
do $$ begin
  assert (select statut from public.encaissements where numero = 'REC-ALPHA-DONKA-2026-A0101') = 'annule', 'D annule après clôture';
end $$;

-- G ne voit pas les clôtures
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.clotures_caisse) = 0, 'G ne voit pas les clôtures';
end $$;
commit;

\echo 'Test 012 : tout est conforme.'
