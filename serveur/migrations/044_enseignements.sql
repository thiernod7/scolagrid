-- 044 : qui enseigne quoi, et ce que chaque enseignant voit et saisit.
--
-- Un enseignement = une personne, une matière, une classe (donc une année),
-- du « début » à la « fin » (vide : jusqu'à la fin de l'année). On le termine,
-- on ne l'efface pas : les notes déjà saisies restent valables. Un remplaçant
-- temporaire est un enseignement de plus sur la même matière et la même classe.
--
-- Règles :
--  - Saisir une note ou créer une épreuve : la direction des études
--    (planifier_evaluations) partout ; un enseignant (saisir_notes) seulement pour
--    ses classes et ses matières, pendant son enseignement (7 jours de grâce après
--    la fin, pour les notes saisies hors ligne).
--  - Lire : l'enseignant lit ses épreuves et ses notes ; le professeur principal
--    lit toutes les notes de sa classe (sans pouvoir les modifier).
--  - Élèves : un compte seulement « enseignant » ne reçoit que les élèves de ses
--    classes (nom, matricule, photo) ; ni familles, ni santé, ni paiements.
--  - Le droit « saisir_notes » seul ne donne plus la lecture de toutes les notes.
--  - Le téléphone d'un enseignant est actif tout de suite (la validation des
--    postes protège la caisse et les inscriptions, qu'il ne touche pas).

create table public.enseignements (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null,
  classe_id uuid not null references public.classes (id) on delete cascade,
  matiere_id uuid not null references public.matieres (id) on delete cascade,
  service text not null default '',            -- « classe|matière », rempli par le serveur
  debut date not null default current_date,
  fin date,
  remplacant boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fin is null or fin >= debut),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade
);
create index enseignements_personnel_idx on public.enseignements (personnel_id);
create index enseignements_service_idx on public.enseignements (service);
alter table public.enseignements owner to postgres;
alter table public.enseignements replica identity full;
alter table public.enseignements enable row level security;

-- Une épreuve porte aussi son « service » : la synchronisation filtre dessus.
alter table public.evaluations add column service text not null default '';
update public.evaluations set service = classe_id::text || '|' || matiere_id::text;
create index evaluations_service_idx on public.evaluations (service);

create or replace function scolagrid.service_evaluation() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.service := new.classe_id::text || '|' || new.matiere_id::text;
  return new;
end $$;
create trigger service_evaluation before insert or update of classe_id, matiere_id on public.evaluations
  for each row execute function scolagrid.service_evaluation();

create or replace function scolagrid.enseignement_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c record; m record;
begin
  select organisation_id, niveau_id into c from public.classes where id = new.classe_id;
  select organisation_id, niveau_id into m from public.matieres where id = new.matiere_id;
  if c.organisation_id is distinct from new.organisation_id or m.organisation_id is distinct from new.organisation_id then
    raise exception 'Classe ou matière d''une autre école' using errcode = '42501';
  end if;
  if c.niveau_id is distinct from m.niveau_id then
    raise exception 'Cette matière n''est pas enseignée dans ce niveau' using errcode = '23514';
  end if;
  new.service := new.classe_id::text || '|' || new.matiere_id::text;
  new.updated_at := now();
  return new;
end $$;
create trigger enseignement_controle before insert or update on public.enseignements
  for each row execute function scolagrid.enseignement_controle();

-- Mes fiches (une par école où j'ai un compte).
create or replace function scolagrid.mes_fiches() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select id from public.personnel where user_id = auth.uid() and statut = 'actif'
$$;

-- Les classes que je suis : où j'enseigne (même terminé), ou dont je suis professeur principal.
create or replace function scolagrid.mes_classes() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select classe_id from public.enseignements where personnel_id in (select scolagrid.mes_fiches())
  union
  select id from public.classes where professeur_principal_id in (select scolagrid.mes_fiches())
$$;

-- Je lis les notes de cette matière dans cette classe ?
create or replace function scolagrid.lit_service(org uuid, classe uuid, matiere uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.lit_notes(org)
      or exists (select 1 from public.enseignements
                 where classe_id = classe and matiere_id = matiere and personnel_id in (select scolagrid.mes_fiches()))
      or exists (select 1 from public.classes
                 where id = classe and professeur_principal_id in (select scolagrid.mes_fiches()))
$$;

-- Je saisis dans cette matière et cette classe, aujourd'hui ?
create or replace function scolagrid.peut_saisir(org uuid, classe uuid, matiere uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.a_le_droit_quelque_part(org, 'planifier_evaluations')
      or (scolagrid.a_le_droit_quelque_part(org, 'saisir_notes')
          and exists (select 1 from public.enseignements
                      where classe_id = classe and matiere_id = matiere
                        and personnel_id in (select scolagrid.mes_fiches())
                        and debut <= current_date and (fin is null or fin + 7 >= current_date)))
$$;

create or replace function scolagrid.peut_saisir_evaluation(ev uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select scolagrid.peut_saisir(organisation_id, classe_id, matiere_id) from public.evaluations where id = ev), false)
$$;

create or replace function scolagrid.lit_evaluation(ev uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select scolagrid.lit_service(organisation_id, classe_id, matiere_id) from public.evaluations where id = ev), false)
$$;

-- J'enseigne (ou j'ai enseigné) dans cette école : je lis ses périodes, types, sessions, règles.
create or replace function scolagrid.enseigne_dans(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.enseignements where organisation_id = org and personnel_id in (select scolagrid.mes_fiches()))
      or exists (select 1 from public.classes where organisation_id = org and professeur_principal_id in (select scolagrid.mes_fiches()))
$$;

-- Je vois tous les élèves de l'école : j'y ai une fonction autre qu'enseignant.
create or replace function scolagrid.lit_tous_eleves(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and role <> 'enseignant')
$$;

create or replace function scolagrid.mes_eleves() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select eleve_id from public.inscriptions where classe_id in (select scolagrid.mes_classes())
$$;

-- Qui règle les enseignements : la direction (fondateur, directeur) et la direction des études.
create or replace function scolagrid.gere_enseignements(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.a_le_droit_quelque_part(org, 'planifier_evaluations')
      or exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and role in ('fondateur', 'directeur'))
$$;

do $$ declare f text; begin
  foreach f in array array['mes_fiches()', 'mes_classes()', 'lit_service(uuid, uuid, uuid)', 'peut_saisir(uuid, uuid, uuid)',
    'peut_saisir_evaluation(uuid)', 'lit_evaluation(uuid)', 'enseigne_dans(uuid)', 'lit_tous_eleves(uuid)', 'mes_eleves()',
    'gere_enseignements(uuid)'] loop
    execute format('revoke all on function scolagrid.%s from public', f);
    execute format('grant execute on function scolagrid.%s to authenticated', f);
  end loop;
end $$;
revoke all on function scolagrid.service_evaluation(), scolagrid.enseignement_controle() from public;

-- Lire toutes les notes : direction des études, tableau de bord, secrétariat (bulletins).
-- « Saisir les notes » seul ne suffit plus : l'enseignant lit les siennes.
create or replace function scolagrid.recalculer_lectures(fiche uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare org uuid; compte uuid;
begin
  select organisation_id, user_id into org, compte from public.personnel where id = fiche;
  if compte is null then return; end if;
  update public.rattachements r set
    lit_familles = x.familles, lit_caisse = x.caisse, lit_personnel = x.personnel, lit_notes = x.notes, updated_at = now()
  from (
    select r2.id,
           scolagrid.rattachement_a(r2, fiche, 'voir_familles') as familles,
           scolagrid.rattachement_a(r2, fiche, 'voir_caisse') or scolagrid.rattachement_a(r2, fiche, 'consulter_tableau_bord') as caisse,
           scolagrid.rattachement_a(r2, fiche, 'voir_personnel') as personnel,
           scolagrid.rattachement_a(r2, fiche, 'planifier_evaluations')
             or scolagrid.rattachement_a(r2, fiche, 'consulter_tableau_bord')
             or scolagrid.rattachement_a(r2, fiche, 'gerer_inscriptions') as notes
    from public.rattachements r2 where r2.organisation_id = org and r2.user_id = compte
  ) x
  where r.id = x.id
    and (r.lit_familles, r.lit_caisse, r.lit_personnel, r.lit_notes) is distinct from (x.familles, x.caisse, x.personnel, x.notes);
end $$;
revoke all on function scolagrid.recalculer_lectures(uuid) from public;

do $$ declare f record; begin
  for f in select id from public.personnel where user_id is not null loop
    perform scolagrid.recalculer_lectures(f.id);
  end loop;
end $$;

-- Règles d'accès des enseignements.
grant select, insert, update, delete on public.enseignements to authenticated;
create policy "membres lisent" on public.enseignements for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "direction ajoute" on public.enseignements for insert to authenticated
  with check (scolagrid.gere_enseignements(organisation_id));
create policy "direction modifie" on public.enseignements for update to authenticated
  using (scolagrid.gere_enseignements(organisation_id)) with check (scolagrid.gere_enseignements(organisation_id));
create policy "direction supprime" on public.enseignements for delete to authenticated
  using (scolagrid.gere_enseignements(organisation_id));

-- Épreuves et notes : la saisie suit les enseignements.
drop policy "saisie" on public.evaluations;
drop policy "saisie (modif)" on public.evaluations;
drop policy "saisie (suppression)" on public.evaluations;
create policy "saisie" on public.evaluations for insert to authenticated
  with check (scolagrid.peut_saisir(organisation_id, classe_id, matiere_id));
create policy "saisie (modif)" on public.evaluations for update to authenticated
  using (scolagrid.peut_saisir(organisation_id, classe_id, matiere_id))
  with check (scolagrid.peut_saisir(organisation_id, classe_id, matiere_id));
create policy "saisie (suppression)" on public.evaluations for delete to authenticated
  using (scolagrid.peut_saisir(organisation_id, classe_id, matiere_id));
create policy "enseignant : lecture" on public.evaluations for select to authenticated
  using (scolagrid.lit_service(organisation_id, classe_id, matiere_id));

drop policy "saisie" on public.notes;
drop policy "saisie (modif)" on public.notes;
drop policy "saisie (suppression)" on public.notes;
create policy "saisie" on public.notes for insert to authenticated
  with check (scolagrid.peut_saisir_evaluation(evaluation_id));
create policy "saisie (modif)" on public.notes for update to authenticated
  using (scolagrid.peut_saisir_evaluation(evaluation_id)) with check (scolagrid.peut_saisir_evaluation(evaluation_id));
create policy "saisie (suppression)" on public.notes for delete to authenticated
  using (scolagrid.peut_saisir_evaluation(evaluation_id));
create policy "enseignant : lecture" on public.notes for select to authenticated
  using (scolagrid.lit_evaluation(evaluation_id));
create policy "enseignant : lecture" on public.notes_historique for select to authenticated
  using (scolagrid.lit_evaluation(evaluation_id));

-- L'appréciation générale du bulletin : la direction des études ou le professeur principal.
drop policy "saisie" on public.appreciations;
drop policy "saisie (modif)" on public.appreciations;
create or replace function scolagrid.peut_apprecier(org uuid, eleve uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.a_le_droit_quelque_part(org, 'planifier_evaluations')
      or exists (select 1 from public.inscriptions i join public.classes c on c.id = i.classe_id
                 where i.eleve_id = eleve and c.professeur_principal_id in (select scolagrid.mes_fiches()))
$$;
revoke all on function scolagrid.peut_apprecier(uuid, uuid) from public;
grant execute on function scolagrid.peut_apprecier(uuid, uuid) to authenticated;
create policy "saisie" on public.appreciations for insert to authenticated
  with check (scolagrid.peut_apprecier(organisation_id, eleve_id));
create policy "saisie (modif)" on public.appreciations for update to authenticated
  using (scolagrid.peut_apprecier(organisation_id, eleve_id)) with check (scolagrid.peut_apprecier(organisation_id, eleve_id));
create policy "enseignant : lecture" on public.appreciations for select to authenticated
  using (eleve_id in (select scolagrid.mes_eleves()) and scolagrid.peut_apprecier(organisation_id, eleve_id));

-- Réglages des évaluations : lus aussi par ceux qui enseignent.
do $$ declare t text; begin
  foreach t in array array['periodes_evaluation', 'types_evaluation', 'sessions_evaluation', 'regles_notes', 'mentions_notes'] loop
    execute format('create policy "enseignant : lecture" on public.%I for select to authenticated using (scolagrid.enseigne_dans(organisation_id))', t);
  end loop;
end $$;

-- Élèves : tous pour le personnel administratif, ceux de ses classes pour l'enseignant.
drop policy "membres lisent" on public.eleves;
create policy "membres lisent" on public.eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations())
         and (scolagrid.lit_tous_eleves(organisation_id) or id in (select scolagrid.mes_eleves())));
drop policy "membres lisent" on public.inscriptions;
create policy "membres lisent" on public.inscriptions for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations())
         and (scolagrid.lit_tous_eleves(organisation_id) or classe_id in (select scolagrid.mes_classes())));
drop policy "membres lisent" on public.photos_eleves;
create policy "membres lisent" on public.photos_eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations())
         and (scolagrid.lit_tous_eleves(organisation_id) or eleve_id in (select scolagrid.mes_eleves())));
drop policy "membres lisent" on public.historique_eleves;
create policy "membres lisent" on public.historique_eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()) and scolagrid.lit_tous_eleves(organisation_id));

-- Le téléphone d'un enseignant est actif tout de suite.
create or replace function public.activer_poste(
  organisation uuid, site uuid, nom text, plateforme text default null, version_app text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  suivant integer;
  poste public.postes;
begin
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  if not scolagrid.travaille_sur(organisation, site) then
    raise exception 'Vous ne travaillez pas sur ce site' using errcode = '42501';
  end if;
  perform 1 from public.organisations where id = organisation for update;
  select coalesce(max(numero), 0) + 1 into suivant from public.postes where organisation_id = organisation;
  if suivant > 2000 then
    raise exception 'Nombre maximal de postes atteint' using errcode = '54000';
  end if;
  insert into public.postes (organisation_id, site_id, numero, code, nom, plateforme, version_app, user_id, derniere_synchro, statut)
  values (organisation, site, suivant, scolagrid.code_poste(suivant), trim(nom),
          left(plateforme, 20), left(version_app, 20), moi, now(),
          -- La direction active elle-même ; un enseignant (notes seulement) aussi ;
          -- les autres attendent la validation de la direction.
          case when scolagrid.gere_perimetre(organisation, site) then 'actif'
               when not scolagrid.lit_tous_eleves(organisation) then 'actif'
               else 'a_valider' end)
  returning * into poste;
  return jsonb_build_object('id', poste.id, 'code', poste.code, 'statut', poste.statut);
end $$;
revoke all on function public.activer_poste(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.activer_poste(uuid, uuid, text, text, text) to authenticated;

alter publication powersync add table public.enseignements;
