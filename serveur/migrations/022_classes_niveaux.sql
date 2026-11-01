-- 022 : niveaux et classes enrichis.
--
-- Niveaux : nom d'usage (CP1 = « 1ère année »), classe d'examen (CEE, BEPC,
-- BAC), séries du lycée, dernier niveau de l'école (après lui : diplômé).
-- Classes : série, lettre, professeur principal ; une classe se referme au lieu
-- d'être supprimée, une fois ses élèves répartis ailleurs.
-- Frais d'examen : un frais « autre » d'un niveau d'examen, dû par tous ses
-- élèves sans souscription.
-- Redoublement : calculé par le serveur (même niveau que l'année précédente) ;
-- la limite de l'école sert d'alerte à la réinscription.

alter table public.niveaux
  add column nom_usage text check (nom_usage is null or length(trim(nom_usage)) between 1 and 60),
  add column examen text check (examen is null or examen in ('CEE', 'BEPC', 'BAC')),
  add column series text check (series is null or series ~ '^(SM|SE|SS|SL)(,(SM|SE|SS|SL))*$'),
  add column niveau_final boolean not null default false;

alter table public.classes
  add column serie text check (serie is null or serie in ('SM', 'SE', 'SS', 'SL')),
  add column lettre text check (lettre is null or lettre ~ '^[A-Z0-9]{1,3}$'),
  add column professeur_principal_id uuid,
  add column fermee boolean not null default false,
  add column fermee_le timestamptz,
  add constraint classes_professeur_principal
    foreign key (professeur_principal_id, organisation_id) references public.personnel (id, organisation_id)
    on delete set null (professeur_principal_id);

alter table public.organisations
  add column redoublements_max integer not null default 1 check (redoublements_max between 0 and 5);

alter table public.inscriptions
  add column redoublant boolean not null default false;

alter table public.frais
  add column examen boolean not null default false,
  add constraint frais_examen_niveau check (not examen or (type_frais = 'optionnel' and niveau_id is not null));

-- Une classe ne se referme que vide ; la rouvrir efface la date.
create or replace function scolagrid.classe_fermeture() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.fermee and not old.fermee then
    if exists (select 1 from public.inscriptions i where i.classe_id = new.id
               and i.statut in ('en_attente', 'actif', 'suspendu')) then
      raise exception 'Il reste des élèves dans cette classe : répartissez-les avant de la refermer' using errcode = '23514';
    end if;
    new.fermee_le := now();
  elsif not new.fermee then
    new.fermee_le := null;
  else
    new.fermee_le := old.fermee_le;
  end if;
  return new;
end $$;
create trigger classe_fermeture before update on public.classes
  for each row execute function scolagrid.classe_fermeture();

-- On n'inscrit ni ne déplace personne dans une classe refermée. Le
-- redoublement se déduit de l'année précédente : jamais saisi par le poste.
create or replace function scolagrid.inscription_classe_ouverte() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  niveau uuid;
  precedent uuid;
begin
  if tg_op = 'INSERT' or new.classe_id is distinct from old.classe_id then
    if (select fermee from public.classes where id = new.classe_id) then
      raise exception 'Cette classe est refermée' using errcode = '23514';
    end if;
  end if;
  select niveau_id into niveau from public.classes where id = new.classe_id;
  select c.niveau_id into precedent
    from public.inscriptions i
    join public.annees_scolaires a on a.id = i.annee_id
    join public.classes c on c.id = i.classe_id
    where i.eleve_id = new.eleve_id and i.id <> new.id
      and a.debut < (select debut from public.annees_scolaires where id = new.annee_id)
      and i.statut <> 'annule'
    order by a.debut desc limit 1;
  new.redoublant := precedent is not null and precedent = niveau;
  return new;
end $$;
revoke all on function scolagrid.inscription_classe_ouverte() from public;
create trigger inscription_classe_ouverte before insert or update on public.inscriptions
  for each row execute function scolagrid.inscription_classe_ouverte();

-- Les écoles qui ont pris le modèle guinéen : noms d'usage, examens, séries.
update public.niveaux n set nom_usage = m.usage, examen = m.examen, series = m.series
from (values
  ('CP1', '1ère année', null, null), ('CP2', '2ème année', null, null),
  ('CE1', '3ème année', null, null), ('CE2', '4ème année', null, null),
  ('CM1', '5ème année', null, null), ('CM2', '6ème année', 'CEE', null),
  ('7ème', '7ème année', null, null), ('8ème', '8ème année', null, null),
  ('9ème', '9ème année', null, null), ('10ème', '10ème année', 'BEPC', null),
  ('11ème', '11ème année', null, 'SM,SE,SS,SL'), ('12ème', '12ème année', null, 'SM,SE,SS,SL'),
  ('Terminale', 'Terminale', 'BAC', 'SM,SE,SS,SL')
) as m(nom, usage, examen, series)
where n.nom = m.nom and n.nom_usage is null;

update public.niveaux n set niveau_final = true
where n.ordre = (select max(x.ordre) from public.niveaux x where x.organisation_id = n.organisation_id)
  and not exists (select 1 from public.niveaux y where y.organisation_id = n.organisation_id and y.niveau_final);
