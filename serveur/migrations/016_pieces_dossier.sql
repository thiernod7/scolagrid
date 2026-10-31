-- 016 : pièces du dossier d'inscription.
--
-- Les pièces remises par la famille (extrait de naissance, photo, carnet de
-- vaccination…) sont cochées à l'inscription. Toutes sont facultatives : on
-- garde seulement la liste des codes cochés, séparés par des virgules.

alter table public.eleves add column pieces_dossier text
  check (pieces_dossier is null
         or (length(pieces_dossier) <= 300 and pieces_dossier ~ '^[a-z_]{2,30}(,[a-z_]{2,30})*$'));
