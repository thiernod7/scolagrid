-- Test de la migration 034 : dépenses (seuil, demande, autorisation, vive voix, clôture).
-- S : secrétaire du site 1 (encaisse). D : directeur du site 1 (autorise).
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
select id as fiche_d from public.personnel where user_id = :'d' and organisation_id = :'org' \gset
select set_config('test.org', :'org', false), set_config('test.site', :'site', false), set_config('test.fiche_d', :'fiche_d', false);

-- Sous le seuil (100 000) : la secrétaire sort l'argent seule.
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.depenses (organisation_id, site_id, montant_gnf, date_effective, categorie, motif)
  values (:'org', :'site', 45000, current_date, 'Fournitures', '3 ramettes A4 pour le secrétariat') returning id as petite \gset
-- Au-dessus : une demande.
insert into public.depenses (organisation_id, site_id, montant_gnf, date_effective, categorie, motif, beneficiaire)
  values (:'org', :'site', 350000, current_date, 'Entretien et réparation', 'Réparation de six tables', 'Menuisier')
  returning id as grosse \gset
select set_config('test.grosse', :'grosse', false);
do $$ begin
  assert (select statut from public.depenses where motif like '3 ramettes%') = 'sortie', 'Sous le seuil : sortie';
  assert (select statut from public.depenses where id = current_setting('test.grosse')::uuid) = 'demande', 'Au-dessus : demande';
  begin
    update public.depenses set statut = 'autorisee' where id = current_setting('test.grosse')::uuid;
    raise exception 'ÉCHEC : la secrétaire a autorisé sa propre dépense';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.depenses (organisation_id, site_id, montant_gnf, date_effective, categorie, motif, autorisation_orale, autorise_oralement_par)
      values (current_setting('test.org')::uuid, current_setting('test.site')::uuid, 280000, current_date, 'Entretien et réparation',
              'Réparation du groupe électrogène', true, current_setting('test.fiche_d')::uuid);
    raise exception 'ÉCHEC : autorisation de vive voix acceptée sans l''accord de l''école';
  exception when check_violation then null;
  end;
end $$;
reset role;

-- Le directeur autorise ; la secrétaire sort l'argent.
select pg_temp.connecte(:'d');
set local role authenticated;
update public.depenses set statut = 'autorisee' where id = :'grosse';
reset role;
select pg_temp.connecte(:'s');
set local role authenticated;
update public.depenses set statut = 'sortie' where id = :'grosse';
reset role;

-- De vive voix, une fois l'option activée : sortie tout de suite, à confirmer.
update public.organisations set depense_orale = true where id = :'org';
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.depenses (organisation_id, site_id, montant_gnf, date_effective, categorie, motif, autorisation_orale, autorise_oralement_par)
  values (:'org', :'site', 280000, current_date, 'Entretien et réparation', 'Réparation du groupe électrogène', true, :'fiche_d')
  returning id as orale \gset
reset role;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.depenses set confirmation = 'confirmee' where id = :'orale';
reset role;
select set_config('test.orale', :'orale', false);
do $$ begin
  assert (select statut from public.depenses where id = current_setting('test.grosse')::uuid) = 'sortie', 'Autorisée puis sortie';
  assert (select statut || '|' || confirmation from public.depenses where id = current_setting('test.orale')::uuid) = 'sortie|confirmee',
    'Vive voix : sortie, puis confirmée';
end $$;

-- Clôture : les dépenses du jour (45 000 + 350 000 + 280 000) sont déduites des espèces attendues.
select pg_temp.connecte(:'s');
set local role authenticated;
select coalesce(sum(total_gnf) filter (where mode = 'especes'), 0) as especes from public.encaissements
  where organisation_id = :'org' and site_id = :'site' and encaisse_par = :'s' and date_effective = current_date and statut = 'valide' \gset
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes, justification)
  values (:'org', :'site', :'s', current_date, 0, 'Test des dépenses') returning attendu_especes \gset
reset role;
select set_config('test.attendu', :'attendu_especes', false), set_config('test.especes', :'especes', false);
do $$ begin
  assert current_setting('test.attendu')::bigint = current_setting('test.especes')::bigint - 675000, 'Dépenses déduites à la clôture';
end $$;
-- Journée clôturée : la dépense ne s'annule plus.
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  begin
    update public.depenses set statut = 'annulee', motif_annulation = 'Erreur de saisie' where id = current_setting('test.grosse')::uuid;
    raise exception 'ÉCHEC : dépense d''une journée clôturée annulée';
  exception when check_violation then null;
  end;
end $$;
reset role;
select 'Test 034 : tout est conforme.';
rollback;
