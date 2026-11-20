-- Deux enseignants FICTIFS pour l'école de démonstration (ESSAI seulement), pour
-- vérifier « Enseignants par classe » et la fiche d'un enseignant :
--  - Mamadou DIALLO, maître de la CP1 A (toutes ses matières), professeur principal ;
--  - Fatoumata CAMARA, Calcul en CE2 A.
-- Les autres matières restent sans enseignant (signalées en orange).
-- Rejouable : ne fait rien s'ils existent déjà. Pas de compte, pas de téléphone.
-- Variable psql : tel (numéro de test de l'école de démonstration).
\set ON_ERROR_STOP on
begin;
select o.id as org
  from auth.users u join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  where u.phone = :'tel' limit 1 \gset
select count(*) > 0 as deja from public.personnel where organisation_id = :'org' and nom_complet = 'Mamadou DIALLO' \gset
\if :deja
  \echo 'Enseignants de démonstration déjà présents.'
  rollback;
  \quit
\endif
select c.id as cp1a, c.niveau_id as n_cp1 from public.classes c join public.annees_scolaires a on a.id = c.annee_id and a.en_cours
  where c.organisation_id = :'org' and c.nom = 'CP1 A' limit 1 \gset
select c.id as ce2a, c.niveau_id as n_ce2 from public.classes c join public.annees_scolaires a on a.id = c.annee_id and a.en_cours
  where c.organisation_id = :'org' and c.nom = 'CE2 A' limit 1 \gset
select a.debut as debut from public.annees_scolaires a where a.organisation_id = :'org' and a.en_cours \gset

insert into public.personnel (organisation_id, nom_complet) values (:'org', 'Mamadou DIALLO') returning id as maitre \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'maitre', 'enseignant');
insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id, debut)
  select :'org', :'maitre', :'cp1a', m.id, :'debut' from public.matieres m where m.niveau_id = :'n_cp1';
update public.classes set professeur_principal_id = :'maitre' where id = :'cp1a';

insert into public.personnel (organisation_id, nom_complet) values (:'org', 'Fatoumata CAMARA') returning id as prof \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'prof', 'enseignant');
insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id, debut)
  select :'org', :'prof', :'ce2a', m.id, :'debut' from public.matieres m where m.niveau_id = :'n_ce2' and m.nom = 'Calcul';
commit;
\echo 'Enseignants de démonstration créés.'
