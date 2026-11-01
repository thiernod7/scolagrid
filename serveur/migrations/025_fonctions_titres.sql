-- 025 : titres et cumul des fonctions.
--
-- Une personne cumule des fonctions (Principal et Directeur général…). Le titre
-- dit à l'école (Proviseur, Censeur…) est porté par « libelle » ; la fonction
-- donne les droits (Proviseur → directeur, Censeur → directeur des études).
-- Deux titres de même fonction sur le même site deviennent possibles.

alter table public.affectations drop constraint affectations_personnel_id_site_id_fonction_key;
alter table public.affectations add constraint affectations_personne_site_titre
  unique nulls not distinct (personnel_id, site_id, fonction, libelle);
