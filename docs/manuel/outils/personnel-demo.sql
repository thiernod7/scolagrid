-- Une caissière FICTIVE pour l'école de démonstration (ESSAI seulement), pour
-- vérifier la fiche du personnel et ses « Pages visibles » (Dépenses masquée).
-- Rejouable : ne fait rien si elle existe déjà. Pas de compte, pas de téléphone.
-- Variable psql : tel (numéro de test de l'école de démonstration).
\set ON_ERROR_STOP on
begin;
select o.id as org
  from auth.users u join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  where u.phone = :'tel' limit 1 \gset
select count(*) > 0 as deja from public.personnel where organisation_id = :'org' and nom_complet = 'Mariama KOUROUMA' \gset
\if :deja
  \echo 'Personnel de démonstration déjà présent.'
  rollback;
  \quit
\endif
insert into public.personnel (organisation_id, nom_complet) values (:'org', 'Mariama KOUROUMA') returning id as fiche \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'fiche', 'caissier');
insert into public.droits_personnel (organisation_id, personnel_id, droit, accorde) values (:'org', :'fiche', 'masquer_depenses', true);
commit;
\echo 'Personnel de démonstration créé.'
