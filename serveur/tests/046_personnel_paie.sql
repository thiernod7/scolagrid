-- Test de la migration 046 : fiche et statuts, rémunération, avances, paie du mois (préparer, valider, verser).
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set g '77777777-7777-7777-7777-777777777777'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
select id as fiche_g from public.personnel where user_id = :'g' and organisation_id = :'org' \gset
select set_config('test.org', :'org', false), set_config('test.fiche_g', :'fiche_g', false);

-- Le fondateur complète la fiche de G et règle sa paie (à l'heure au collège, 25 000).
select pg_temp.connecte(:'a');
set local role authenticated;
update public.personnel set date_embauche = '2024-10-01', contrat = 'vacataire', sexe = 'M', contact_urgence = 'Mme Sow 620 00 00 01'
 where id = :'fiche_g';
insert into public.remunerations (organisation_id, personnel_id, mode) values (:'org', :'fiche_g', 'horaire');
insert into public.grille_taux (organisation_id, cycle, taux_gnf) values (:'org', 'college', 25000);
insert into public.taux_horaires (organisation_id, personnel_id, cycle, taux_gnf) values (:'org', :'fiche_g', 'college', 25000);
-- Une avance de 300 000 en espèces, sur 3 mois : une dépense sort de la caisse.
insert into public.avances (organisation_id, personnel_id, montant_gnf, mensualites, motif)
  values (:'org', :'fiche_g', 300000, 3, 'Frais médicaux') returning id as avance \gset
select set_config('test.avance', :'avance', false);
do $$ begin
  assert (select d.statut = 'sortie' and d.categorie = 'Avances sur salaire' and d.montant_gnf = 300000
          from public.avances a join public.depenses d on d.id = a.depense_id where a.id = current_setting('test.avance')::uuid),
    'L''avance sort de la caisse';
  -- Le montant d'une avance versée ne change plus.
  begin
    update public.avances set montant_gnf = 1 where id = current_setting('test.avance')::uuid;
    assert false, 'Montant d''avance modifié';
  exception when check_violation then null;
  end;
end $$;

-- La paie de novembre : préparée, une ligne (24 h × 25 000 = 600 000, retenue d'avance 100 000).
insert into public.paies (organisation_id, mois) values (:'org', '2026-11-01') returning id as paie \gset
select set_config('test.paie', :'paie', false);
insert into public.lignes_paie (organisation_id, paie_id, personnel_id, mode, heures_gnf, retenue_avance_gnf, net_gnf, detail)
  values (:'org', :'paie', :'fiche_g', 'horaire', 600000, 100000, 500000, '[{"classe":"7ème A","prevues":24,"faites":24,"taux":25000}]')
  returning id as ligne \gset
select set_config('test.ligne', :'ligne', false);
do $$ begin
  -- Un net faux est refusé.
  begin
    update public.lignes_paie set net_gnf = 900000 where id = current_setting('test.ligne')::uuid;
    assert false, 'Net incohérent accepté';
  exception when check_violation then null;
  end;
  -- Pas de versement avant la validation.
  begin
    update public.lignes_paie set versee_le = current_date, versement_mode = 'especes' where id = current_setting('test.ligne')::uuid;
    assert false, 'Versement avant validation';
  exception when check_violation then null;
  end;
end $$;
-- Validée : les montants sont figés ; le versement en espèces sort de la caisse.
update public.paies set statut = 'validee' where id = :'paie';
do $$ begin
  assert (select validee_par is not null from public.paies where id = current_setting('test.paie')::uuid), 'Validation tracée';
  begin
    update public.lignes_paie set primes_gnf = 50000, net_gnf = 550000 where id = current_setting('test.ligne')::uuid;
    assert false, 'Paie validée modifiée';
  exception when check_violation then null;
  end;
end $$;
update public.lignes_paie set versee_le = current_date, versement_mode = 'especes' where id = :'ligne';
do $$ begin
  assert (select d.statut = 'sortie' and d.categorie = 'Salaires' and d.montant_gnf = 500000 and l.versee_par is not null
          from public.lignes_paie l join public.depenses d on d.id = l.depense_id where l.id = current_setting('test.ligne')::uuid),
    'Le salaire sort de la caisse';
  begin
    update public.lignes_paie set versee_le = null, versement_mode = null where id = current_setting('test.ligne')::uuid;
    assert false, 'Versement annulé';
  exception when check_violation then null;
  end;
  begin
    update public.paies set statut = 'preparation' where id = current_setting('test.paie')::uuid;
    assert false, 'Paie rouverte après un versement';
  exception when check_violation then null;
  end;
end $$;
reset role;

-- G (enseignant, sans droit de paie) ne voit aucun salaire ; en congé, son accès est coupé.
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.lignes_paie) = 0, 'Un enseignant voit la paie';
  assert (select count(*) from public.remunerations) = 0, 'Un enseignant voit les salaires';
  assert (select count(*) from public.avances) = 0, 'Un enseignant voit les avances';
end $$;
reset role;
update public.personnel set statut = 'conge', statut_depuis = current_date, statut_jusqu_au = current_date + 30 where id = :'fiche_g';
do $$ begin
  assert not exists (select 1 from public.rattachements r join public.personnel p on p.user_id = r.user_id and p.organisation_id = r.organisation_id
                     where p.id = current_setting('test.fiche_g')::uuid and r.actif), 'En congé : accès coupé';
end $$;
rollback;
\echo '046 personnel et paie : OK'
