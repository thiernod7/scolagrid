-- Une fois : retire l'école de démonstration créée par erreur avec le numéro de test
-- 224620000004 (déjà membre d'une école d'essai) et rend son nom au compte.
\set ON_ERROR_STOP on
begin;
select id as u from auth.users where phone = '224620000004' \gset
delete from public.organisations where cree_par = :'u' and nom = 'Groupe scolaire Les Manguiers';
update public.personnes p set nom_complet = x.nom_complet
  from (select nom_complet from public.personnel where user_id = :'u' order by created_at limit 1) x
  where p.id = :'u';
commit;
\echo 'Compte de test 0004 remis en état.'
