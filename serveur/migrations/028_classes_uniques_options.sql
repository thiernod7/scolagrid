-- 028 : une classe n'existe qu'une fois ; les options du lycée suivent le jeu de l'école.
--
-- 1. Deux classes ouvertes du même site et de la même année ne peuvent plus
--    porter le même nom (« 10ème A » deux fois). Les doublons déjà présents
--    sont renommés « 10ème A (2) » pour que la direction les repère et ferme
--    ou renomme celle en trop.
-- 2. Options du lycée (Paramétrage §4.1) : l'école choisit un jeu.
--    Type 1 : SS (série scientifique), SL (série littéraire).
--    Type 2 : SM (sciences mathématiques), SS (sciences sociales), SE (sciences expérimentales).
--    L'ancien modèle mélangeait les deux (SM, SE, SS, SL) : on range chaque
--    école dans le type 2 si elle a SM ou SE, sinon dans le type 1.

with d as (
  select id, row_number() over (
           partition by site_id, annee_id, lower(regexp_replace(trim(nom), '\s+', ' ', 'g')) order by created_at, id) as rang
  from public.classes where not fermee
)
update public.classes c set nom = left(c.nom, 54) || ' (' || d.rang || ')', updated_at = now()
from d where d.id = c.id and d.rang > 1;

create unique index classes_nom_unique on public.classes
  (site_id, annee_id, lower(regexp_replace(trim(nom), '\s+', ' ', 'g'))) where not fermee;

update public.niveaux n set series = case
    when exists (select 1 from public.niveaux x where x.organisation_id = n.organisation_id and x.cycle = 'lycee'
                 and (x.series like '%SM%' or x.series like '%SE%')) then 'SM,SS,SE'
    else 'SS,SL' end,
  updated_at = now()
where n.cycle = 'lycee' and n.series is not null and n.series <> '';

alter table public.niveaux add constraint niveaux_series_jeu
  check (series is null or series = '' or series in ('SM,SS,SE', 'SS,SL'));
