-- Diagnostic de la paie de l'école de démonstration (essai), LECTURE SEULE.
-- Le journal est public : uniquement des nombres et des noms de mois.
\pset footer off
with u as (select id from auth.users where phone = '224620000009' limit 1),
     o as (select r.organisation_id as id from public.rattachements r, u where r.user_id = u.id limit 1)
select
  (select count(*) from public.rattachements r, u where r.user_id = u.id and r.actif) as rattachements_actifs,
  (select count(*) from public.rattachements r, u where r.user_id = u.id and r.actif and r.lit_paie) as lit_paie,
  (select count(*) from public.rattachements r, u where r.user_id = u.id and r.actif and r.lit_notes) as lit_notes,
  (select count(*) from public.personnel p, o where p.organisation_id = o.id) as personnel,
  (select count(*) from public.remunerations x, o where x.organisation_id = o.id) as remunerations,
  (select count(*) from public.grille_taux x, o where x.organisation_id = o.id) as grille,
  (select count(*) from public.avances x, o where x.organisation_id = o.id) as avances,
  (select count(*) from public.paies x, o where x.organisation_id = o.id) as paies,
  (select count(*) from public.lignes_paie x, o where x.organisation_id = o.id) as lignes_paie;
with u as (select id from auth.users where phone = '224620000009' limit 1),
     o as (select r.organisation_id as id from public.rattachements r, u where r.user_id = u.id limit 1)
select to_char(x.mois, 'YYYY-MM') as mois, x.statut, (select count(*) from public.lignes_paie l where l.paie_id = x.id) as lignes
from public.paies x, o where x.organisation_id = o.id order by x.mois;
