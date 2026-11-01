-- Test de la migration 022 : niveaux et classes enrichis, redoublement, fermeture.
-- D : directeur du site 1. S : secrétaire du site 1.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set s '88888888-8888-8888-8888-888888888888'
\set ins '10000000-0000-0000-0000-000000000001'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select i.eleve_id as eleve, i.site_id as site, i.classe_id as classe, c.niveau_id as niveau, a.fin as fin
  from public.inscriptions i join public.classes c on c.id = i.classe_id join public.annees_scolaires a on a.id = i.annee_id
  where i.id = :'ins' \gset
select set_config('test.org', :'org_a', false), set_config('test.classe', :'classe', false),
       set_config('test.site', :'site', false), set_config('test.niveau', :'niveau', false), set_config('test.eleve', :'eleve', false);

-- Une limite d'un redoublement ; séries et frais d'examen contrôlés.
do $$ begin
  assert (select redoublements_max from public.organisations where id = current_setting('test.org')::uuid) = 1, 'Un redoublement par défaut';
  begin
    update public.niveaux set series = 'SM,XX' where id = current_setting('test.niveau')::uuid;
    raise exception 'Série inconnue acceptée';
  exception when check_violation then null;
  end;
  begin
    insert into public.frais (organisation_id, annee_id, libelle, montant_gnf, type_frais, examen)
      select organisation_id, annee_id, 'Examen', 1000, 'optionnel', true from public.classes where id = current_setting('test.classe')::uuid;
    raise exception 'Frais d''examen sans niveau accepté';
  exception when check_violation then null;
  end;
end $$;

-- Le directeur donne un professeur principal, une série et une lettre.
select id as prof from public.personnel where organisation_id = :'org_a' and site_id = :'site' and user_id is null limit 1 \gset
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.classes set professeur_principal_id = :'prof', lettre = 'A' where id = :'classe';
commit;
do $$ begin
  assert (select professeur_principal_id from public.classes where id = current_setting('test.classe')::uuid) is not null, 'Professeur principal noté';
end $$;

-- Refermer une classe qui a encore des élèves : refusé.
do $$ begin
  begin
    update public.classes set fermee = true where id = current_setting('test.classe')::uuid;
    raise exception 'Classe refermée avec ses élèves';
  exception when check_violation then null;
  end;
end $$;

-- Une classe vide se referme ; on n'y inscrit plus personne ; on la rouvre.
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom, lettre)
  select organisation_id, site_id, annee_id, niveau_id, 'Classe vide Z', 'Z' from public.classes where id = :'classe'
  returning id as vide \gset
select set_config('test.vide', :'vide', false);
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.classes set fermee = true where id = :'vide';
commit;
do $$ begin
  assert (select fermee_le from public.classes where id = current_setting('test.vide')::uuid) is not null, 'Date de fermeture notée';
  begin
    update public.inscriptions set classe_id = current_setting('test.vide')::uuid where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'Élève déplacé dans une classe refermée';
  exception when check_violation then null;
  end;
end $$;
update public.classes set fermee = false where id = :'vide';
do $$ begin
  assert (select fermee_le from public.classes where id = current_setting('test.vide')::uuid) is null, 'Classe rouverte';
end $$;

-- Redoublement : même niveau l'année suivante. Le poste ne peut pas le cacher.
select statut as statut_avant from public.inscriptions where id = :'ins' \gset
update public.inscriptions set statut = 'actif' where id = :'ins';
insert into public.annees_scolaires (organisation_id, libelle, debut, fin, etat)
  values (:'org_a', 'Suivante', :'fin'::date + 60, :'fin'::date + 360, 'inscriptions') returning id as suivante \gset
insert into public.niveaux (organisation_id, cycle, nom, ordre) values (:'org_a', 'college', 'Niveau test 022', 99) returning id as autre \gset
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom)
  values (:'org_a', :'site', :'suivante', :'niveau', 'Même niveau') returning id as meme \gset
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom)
  values (:'org_a', :'site', :'suivante', :'autre', 'Niveau au-dessus') returning id as dessus \gset
insert into public.inscriptions (organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission, redoublant)
  values (:'org_a', :'eleve', :'suivante', :'site', :'meme', 'reinscription', false) returning id as reins \gset
select set_config('test.reins', :'reins', false), set_config('test.dessus', :'dessus', false);
do $$ begin
  assert (select redoublant from public.inscriptions where id = current_setting('test.reins')::uuid), 'Redoublant détecté';
  assert not (select redoublant from public.inscriptions where id = '10000000-0000-0000-0000-000000000001'), 'Première année : pas redoublant';
  update public.inscriptions set classe_id = current_setting('test.dessus')::uuid where id = current_setting('test.reins')::uuid;
  assert not (select redoublant from public.inscriptions where id = current_setting('test.reins')::uuid), 'Passage : plus redoublant';
end $$;

-- Ménage.
delete from public.inscriptions where id = :'reins';
update public.inscriptions set statut = :'statut_avant' where id = :'ins';
delete from public.classes where id in (:'meme', :'dessus', :'vide');
delete from public.niveaux where id = :'autre';
delete from public.annees_scolaires where id = :'suivante';
update public.classes set professeur_principal_id = null, lettre = null where id = :'classe';
\echo 'Test 022 : tout est conforme.'
