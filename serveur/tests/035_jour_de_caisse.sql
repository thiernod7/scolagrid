-- Test de la migration 035 : jour de caisse, dates venues d'une horloge fausse, correction de date.
-- S : secrétaire du site 1 (encaisse). D : directeur du site 1 (annule et corrige les reçus).
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set s '88888888-8888-8888-8888-888888888888'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
select id as site from public.sites where organisation_id = :'org' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org' and en_cours \gset

select pg_temp.connecte(:'s');
set local role authenticated;
-- Payé le 3, saisi aujourd'hui : dans la caisse d'aujourd'hui.
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective, jour_caisse)
  values (:'org', :'site', :'annee', 'REC-JOUR-KAL-2026-J0001', 'Parent J1', 'especes', 70000, current_date - 2, current_date) returning id as r1 \gset
-- Horloge du poste en avance d'un mois : ramené à aujourd'hui, signalé.
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective, jour_caisse)
  values (:'org', :'site', :'annee', 'REC-JOUR-KAL-2026-J0002', 'Parent J2', 'especes', 30000, current_date + 30, current_date + 30) returning id as r2 \gset
-- Poste pas encore à jour (sans jour de caisse) : sa date effective, comme avant.
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective)
  values (:'org', :'site', :'annee', 'REC-JOUR-KAL-2026-J0003', 'Parent J3', 'especes', 10000, current_date - 15) returning id as r3 \gset
-- Horloge en retard (20 octobre au lieu d'aujourd'hui) : accepté tel quel, la direction corrigera.
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective, jour_caisse)
  values (:'org', :'site', :'annee', 'REC-JOUR-KAL-2026-J0004', 'Parent J4', 'especes', 20000, current_date - 16, current_date - 16) returning id as r4 \gset
select set_config('test.r1', :'r1', false), set_config('test.r2', :'r2', false), set_config('test.r3', :'r3', false),
       set_config('test.r4', :'r4', false);
do $$ begin
  assert (select jour_caisse = current_date and date_effective = current_date - 2 and recu_serveur_le is not null
          from public.encaissements where id = current_setting('test.r1')::uuid), 'Payé le 3, en caisse aujourd''hui';
  assert (select jour_caisse = current_date and date_douteuse from public.encaissements where id = current_setting('test.r2')::uuid),
    'Jour à venir ramené à aujourd''hui et signalé';
  assert (select jour_caisse = current_date - 15 from public.encaissements where id = current_setting('test.r3')::uuid),
    'Ancien poste : jour de caisse = date effective';
  -- La secrétaire ne corrige pas la date
  begin
    update public.encaissements set date_effective = current_date, jour_caisse = current_date, motif_correction_date = 'Horloge'
      where id = current_setting('test.r4')::uuid;
    raise exception 'ÉCHEC : la secrétaire a corrigé une date';
  exception when insufficient_privilege then null;
  end;
  -- Une mise à jour ordinaire ne touche pas aux dates
  update public.encaissements set impressions = 1, date_effective = current_date where id = current_setting('test.r1')::uuid;
  assert (select date_effective = current_date - 2 from public.encaissements where id = current_setting('test.r1')::uuid),
    'Date figée hors correction';
end $$;
-- Clôture du jour : le reçu payé le 3 compte aujourd'hui.
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes)
  values (:'org', :'site', :'s', current_date, 100000);
reset role;
do $$ begin
  assert (select attendu_especes from public.clotures_caisse where jour = current_date
          and encaisse_par = '88888888-8888-8888-8888-888888888888') = 100000, 'Clôture par jour de caisse (70 000 + 30 000)';
end $$;

-- Le directeur corrige le reçu mal daté.
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  -- Sans motif : les dates ne bougent pas
  update public.encaissements set date_effective = current_date - 1, jour_caisse = current_date - 1
    where id = current_setting('test.r4')::uuid;
  assert (select date_effective = current_date - 16 from public.encaissements where id = current_setting('test.r4')::uuid),
    'Sans motif, pas de correction';
  begin
    update public.encaissements set date_effective = current_date + 1, jour_caisse = current_date + 1, motif_correction_date = 'Horloge'
      where id = current_setting('test.r4')::uuid;
    raise exception 'ÉCHEC : date dans le futur';
  exception when check_violation then null;
  end;
  begin
    -- Vers une journée clôturée : refusé
    update public.encaissements set date_effective = current_date, jour_caisse = current_date, motif_correction_date = 'Horloge'
      where id = current_setting('test.r4')::uuid;
    raise exception 'ÉCHEC : correction vers une journée clôturée';
  exception when check_violation then null;
  end;
end $$;
update public.encaissements set date_effective = current_date - 1, jour_caisse = current_date - 1,
  motif_correction_date = 'Horloge de l''ordinateur fausse' where id = :'r4';
reset role;
do $$ begin
  assert (select date_effective = current_date - 1 and jour_caisse = current_date - 1 and date_initiale = current_date - 16
          and date_corrigee_par = '44444444-4444-4444-4444-444444444444'
          from public.encaissements where id = current_setting('test.r4')::uuid), 'Date corrigée et tracée';
end $$;
rollback;
\echo '035 jour de caisse : OK'

-- 037 : le poste ne voyait pas d'écart, le serveur en trouve un : clôture gardée, « à vérifier ».
\set s '88888888-8888-8888-8888-888888888888'
begin;
create function pg_temp.connecte2(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = '11111111-1111-1111-1111-111111111111' order by created_at limit 1 \gset
select id as site from public.sites where organisation_id = :'org' and nom = 'Site de Kaloum' \gset
select id as annee from public.annees_scolaires where organisation_id = :'org' and en_cours \gset
select pg_temp.connecte2(:'s');
set local role authenticated;
insert into public.encaissements (organisation_id, site_id, annee_id, numero, payeur_nom, mode, total_gnf, date_effective, jour_caisse)
  values (:'org', :'site', :'annee', 'REC-JOUR-KAL-2026-J0009', 'Parent J9', 'especes', 40000, current_date - 3, current_date - 3);
-- Le poste croyait 0 attendu et a compté 0 : sans écart pour lui.
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes, attendu_especes, ecart)
  values (:'org', :'site', :'s', current_date - 3, 0, 0, 0);
reset role;
do $$ begin
  assert (select a_verifier and ecart = -40000 and justification like 'Écart apparu%' from public.clotures_caisse
          where jour = current_date - 3 and encaisse_par = '88888888-8888-8888-8888-888888888888'
          order by rang desc limit 1), 'Clôture gardée, à vérifier';
end $$;
rollback;
\echo '037 clôture sans refus : OK'
