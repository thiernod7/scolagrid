-- Test de la migration 050 : un responsable de cycle ne voit et n'écrit que dans ses cycles.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set p '50505050-0000-0000-0000-000000000050'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
insert into auth.users (id, aud, role, phone) values (:'p', 'authenticated', 'authenticated', '224620000050');
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
-- Un cycle qui a des élèves (X), et un autre cycle sans élève (Y, créé pour le test).
select n.cycle as x from public.inscriptions i join public.classes c on c.id = i.classe_id join public.niveaux n on n.id = c.niveau_id
  where i.organisation_id = :'org' group by n.cycle order by count(*) desc limit 1 \gset
select c.id as classe_x, c.site_id as site, c.annee_id as annee from public.classes c join public.niveaux n on n.id = c.niveau_id
  where c.organisation_id = :'org' and n.cycle = :'x' and exists (select 1 from public.inscriptions i where i.classe_id = c.id) limit 1 \gset
select m.id as matiere_x from public.matieres m join public.classes c on c.niveau_id = m.niveau_id where c.id = :'classe_x' limit 1 \gset
-- Y : un cycle sans aucun élève inscrit.
select y from unnest(array['maternelle', 'primaire', 'college', 'lycee']) y
  where y <> :'x' and not exists (select 1 from public.inscriptions i join public.classes c on c.id = i.classe_id
                                  join public.niveaux n on n.id = c.niveau_id where i.organisation_id = :'org' and n.cycle = y)
  limit 1 \gset
insert into public.niveaux (organisation_id, nom, ordre, cycle) values (:'org', 'Niveau test 050', 99, :'y') returning id as niveau_y \gset
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom) values (:'org', :'site', :'annee', :'niveau_y', 'Test 050') returning id as classe_y \gset
select count(distinct i.eleve_id) as eleves_x from public.inscriptions i join public.classes c on c.id = i.classe_id
  join public.niveaux n on n.id = c.niveau_id where c.organisation_id = :'org' and n.cycle = :'x' \gset
select i.eleve_id as un_eleve from public.inscriptions i where i.classe_id = :'classe_x' limit 1 \gset

-- Le principal : responsable du cycle X seulement.
insert into public.personnel (organisation_id, nom_complet, telephone) values (:'org', 'Principal Test', '224620000050') returning id as fiche \gset
insert into public.affectations (organisation_id, personnel_id, fonction, libelle, cycles)
  values (:'org', :'fiche', 'responsable_cycle', 'Principal', array[:'x']) returning id as aff \gset
update public.personnel set user_id = :'p' where id = :'fiche';
select set_config('test.org', :'org', false), set_config('test.p', :'p', false), set_config('test.x', :'x', false),
       set_config('test.classe_x', :'classe_x', false), set_config('test.classe_y', :'classe_y', false),
       set_config('test.matiere_x', :'matiere_x', false), set_config('test.y', :'y', false), set_config('test.eleves_x', :'eleves_x', false);

do $$ declare r public.rattachements; n integer; begin
  select * into r from public.rattachements where user_id = current_setting('test.p')::uuid and role = 'responsable_cycle' and actif;
  assert found, 'Rattachement créé';
  assert r.cycles = array[current_setting('test.x')], format('Cycles recopiés : %s', r.cycles);
  assert r.lit_familles and r.lit_notes and not r.lit_caisse, 'Parents et notes, pas la caisse';
  select count(*) into n from public.perimetres where user_id = current_setting('test.p')::uuid;
  assert n = (select count(*) from public.classes c join public.niveaux nv on nv.id = c.niveau_id
              where c.organisation_id = current_setting('test.org')::uuid and nv.cycle = current_setting('test.x')),
    format('Périmètre : les classes du cycle (%s)', n);
  assert not exists (select 1 from public.perimetres where user_id = current_setting('test.p')::uuid
                     and classe_id = current_setting('test.classe_y')::uuid), 'Pas la classe de l''autre cycle';
end $$;

-- Ce qu'il voit : les élèves de son cycle, et rien de l'autre.
select pg_temp.connecte(:'p');
set local role authenticated;
do $$ declare n integer; begin
  select count(*) into n from public.eleves;
  assert n = current_setting('test.eleves_x')::int, format('Élèves vus : %s au lieu de %s', n, current_setting('test.eleves_x'));
  assert not exists (select 1 from public.inscriptions i join public.classes c on c.id = i.classe_id join public.niveaux nv on nv.id = c.niveau_id
                     where nv.cycle <> current_setting('test.x')), 'Aucune inscription hors de son cycle';
  assert not exists (select 1 from public.encaissements), 'Pas la caisse';
  assert scolagrid.peut_saisir(current_setting('test.org')::uuid, current_setting('test.classe_x')::uuid, current_setting('test.matiere_x')::uuid),
    'Il saisit dans son cycle';
  assert not scolagrid.peut_saisir(current_setting('test.org')::uuid, current_setting('test.classe_y')::uuid, current_setting('test.matiere_x')::uuid),
    'Il ne saisit pas hors de son cycle';
  assert scolagrid.couvre_cycle(current_setting('test.org')::uuid, current_setting('test.x')), 'Son cycle';
  assert not scolagrid.couvre_cycle(current_setting('test.org')::uuid, current_setting('test.y')), 'Pas l''autre cycle';
end $$;
-- Il n'inscrit pas dans une classe de l'autre cycle.
do $$ begin
  insert into public.inscriptions (organisation_id, site_id, eleve_id, annee_id, classe_id, statut)
    select organisation_id, site_id, eleve_id, annee_id, current_setting('test.classe_y')::uuid, 'inscrit'
    from public.inscriptions where classe_id = current_setting('test.classe_x')::uuid limit 1;
  assert false, 'Inscription hors de son cycle acceptée';
exception when insufficient_privilege or check_violation or unique_violation then null;
end $$;
-- Il ne touche pas aux types d'évaluation de toute l'école.
do $$ begin
  insert into public.types_evaluation (organisation_id, libelle, poids) values (current_setting('test.org')::uuid, 'Exposé 050', 1);
  assert false, 'Type d''évaluation ajouté par un responsable de cycle';
exception when insufficient_privilege then null;
end $$;
reset role;

-- Son cycle change : il ne voit plus ces élèves.
update public.affectations set cycles = array[:'y'] where id = :'aff';
select pg_temp.connecte(:'p');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.eleves) = 0, 'Plus aucun élève après le changement de cycle';
end $$;
reset role;

-- Toute l'école (cycles vide) : il voit tous les élèves.
update public.affectations set cycles = null where id = :'aff';
do $$ begin
  assert not exists (select 1 from public.perimetres where user_id = current_setting('test.p')::uuid), 'Plus de périmètre limité';
end $$;
select pg_temp.connecte(:'p');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.eleves) >= current_setting('test.eleves_x')::int, 'Tous les élèves';
end $$;
reset role;
rollback;
\echo '050 périmètre par cycles : OK'
