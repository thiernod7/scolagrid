-- 029 : l'ancien matricule de l'école (registre d'avant ScolaGrid).
--
-- Le matricule ScolaGrid reste attribué automatiquement ; l'ancien sert à
-- retrouver l'élève et à éviter de le créer deux fois. Pas d'unicité
-- imposée (un ancien registre peut avoir des erreurs) : l'application
-- prévient quand deux élèves portent le même.

alter table public.eleves
  add column ancien_matricule text check (ancien_matricule is null or length(trim(ancien_matricule)) between 1 and 40);

create index eleves_ancien_matricule_idx on public.eleves (organisation_id, lower(ancien_matricule))
  where ancien_matricule is not null;
