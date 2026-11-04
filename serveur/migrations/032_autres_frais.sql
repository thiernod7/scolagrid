-- 032 : autres frais (internat, cantine, transport…) plus souples.
--
-- Un autre frais peut être OBLIGATOIRE (dû par tous les élèves concernés, comme
-- la scolarité) ou au choix de la famille (souscription, comme avant), être
-- réservé à CERTAINES CLASSES, et se payer en une fois ou selon les tranches de
-- l'année (échéances, comme la scolarité). Un prix par niveau : une ligne de
-- frais par niveau, comme la grille de la scolarité.

alter table public.frais
  add column obligatoire boolean not null default false,
  add column classes text check (classes is null or classes ~ '^[0-9a-f-]{36}(,[0-9a-f-]{36})*$');

alter table public.frais add constraint frais_obligatoire_optionnel
  check (not obligatoire or type_frais = 'optionnel');
