-- Quelques dépenses FICTIVES pour l'école de démonstration (ESSAI seulement),
-- pour vérifier l'écran Dépenses. Rejouable : ne fait rien s'il y en a déjà.
-- Variable psql : tel (numéro de test de l'école de démonstration).
\set ON_ERROR_STOP on
begin;
select o.id as org, s.id as site, u.id as moi
  from auth.users u join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  join public.sites s on s.organisation_id = o.id
  where u.phone = :'tel' limit 1 \gset
select count(*) > 0 as deja from public.depenses where organisation_id = :'org' \gset
\if :deja
  \echo 'Dépenses de démonstration déjà présentes.'
  rollback;
  \quit
\endif
insert into public.depenses (organisation_id, site_id, montant_gnf, date_effective, categorie, motif, beneficiaire, bon, cree_par, created_at)
select :'org', :'site', m, current_date - j, c, mo, b, bon, :'moi', (current_date - j + time '10:30') + make_interval(days => r)
from (values
  (45000, 1, 'Fournitures', '3 ramettes A4 pour le secrétariat', 'Librairie du Centre', '0138', 0),
  (20000, 1, 'Fournitures', 'Craie blanche, 2 boîtes', 'Marché de Kipé', '0139', 0),
  (85000, 2, 'Carburant et énergie', 'Gasoil pour le groupe électrogène', 'Station Total Kipé', '0140', 0),
  (95000, 3, 'Entretien et réparation', 'Réparation de deux tables (7ème A)', 'Menuiserie Bah', '0141', 1),
  (30000, 4, 'Communication', 'Crédit téléphone de la direction', 'Orange', '0142', 0),
  (60000, 5, 'Transport et mission', 'Course à l''inspection de Ratoma', 'Taxi', '0144', 0),
  (25000, 6, 'Fournitures', 'Savon et produits d''entretien', 'Marché de Kipé', null, 0),
  (120000, 8, 'Entretien et réparation', 'Plomberie des toilettes', 'M. Soumah, plombier', '0145', 0)
) as v(m, j, c, mo, b, bon, r);
commit;
\echo 'Dépenses de démonstration créées.'
