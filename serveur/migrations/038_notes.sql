-- 038 : notes et bulletins (lot 1).
--
-- Périodes d'évaluation PAR CYCLE (maternelle 1, primaire 3 trimestres,
-- collège/lycée 2 semestres : défauts réglables), avec le barème du cycle
-- (sur 10, sur 20). Types d'évaluation de l'école (Évaluation poids 1,
-- Composition poids 2, Examen blanc hors moyenne). Une évaluation = une classe,
-- une matière, un type, une date, dans une période. Une note par élève, avec
-- son état : note, absent justifié (exclu), absent (0), dispensé, non concerné,
-- non noté. Une période clôturée fige ses évaluations et ses notes.
--
-- Qui lit les notes : saisir_notes, planifier_evaluations, consulter_tableau_bord,
-- gerer_inscriptions (le secrétariat imprime les bulletins). Qui saisit :
-- saisir_notes ou planifier_evaluations. Qui règle périodes et types, et clôture :
-- planifier_evaluations.

alter table public.rattachements add column lit_notes boolean not null default false;

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
           scolagrid.rattachement_a(r2, fiche, 'saisir_notes') or scolagrid.rattachement_a(r2, fiche, 'planifier_evaluations')
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

create or replace function scolagrid.lit_notes(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and lit_notes)
$$;
revoke all on function scolagrid.lit_notes(uuid) from public;
grant execute on function scolagrid.lit_notes(uuid) to authenticated;

create table public.periodes_evaluation (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  annee_id uuid not null references public.annees_scolaires (id) on delete cascade,
  cycle text not null check (length(trim(cycle)) between 2 and 40),
  ordre integer not null check (ordre between 1 and 6),
  libelle text not null check (length(trim(libelle)) between 2 and 60),
  debut date not null,
  fin date not null check (fin >= debut),
  bareme integer not null default 20 check (bareme in (10, 20, 100)),
  statut text not null default 'ouverte' check (statut in ('ouverte', 'cloturee')),
  cloturee_par uuid references auth.users (id) on delete set null,
  cloturee_le timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (annee_id, cycle, ordre)
);

create table public.types_evaluation (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  libelle text not null check (length(trim(libelle)) between 2 and 40),
  poids numeric(4, 2) not null default 1 check (poids > 0 and poids <= 10),
  compte boolean not null default true,              -- compte dans la moyenne (non : examen blanc)
  unique_par_periode boolean not null default false, -- une seule par période et matière (composition)
  ordre integer not null default 0,
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, libelle)
);

create table public.evaluations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  periode_id uuid not null references public.periodes_evaluation (id) on delete restrict,
  classe_id uuid not null references public.classes (id) on delete cascade,
  matiere_id uuid not null references public.matieres (id) on delete restrict,
  type_id uuid not null references public.types_evaluation (id) on delete restrict,
  date_evaluation date not null,
  libelle text check (libelle is null or length(trim(libelle)) between 1 and 80),
  cree_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index evaluations_classe_idx on public.evaluations (classe_id, periode_id);

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  evaluation_id uuid not null references public.evaluations (id) on delete cascade,
  eleve_id uuid not null references public.eleves (id) on delete cascade,
  valeur numeric(6, 2),
  etat text not null default 'note'
    check (etat in ('note', 'absent_justifie', 'absent', 'dispense', 'non_concerne', 'non_note')),
  bareme integer not null default 20,                -- gardé avec la note : l'historique reste lisible
  saisi_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (evaluation_id, eleve_id),
  check (etat <> 'note' or valeur is not null),
  check (valeur is null or valeur >= 0)
);
create index notes_eleve_idx on public.notes (eleve_id);

-- Appréciation générale du bulletin de période (professeur principal, direction).
create table public.appreciations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  periode_id uuid not null references public.periodes_evaluation (id) on delete cascade,
  eleve_id uuid not null references public.eleves (id) on delete cascade,
  texte text not null check (length(trim(texte)) between 1 and 400),
  par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (periode_id, eleve_id)
);

do $$ declare t text; begin
  foreach t in array array['periodes_evaluation', 'types_evaluation', 'evaluations', 'notes', 'appreciations'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I for each row execute function scolagrid.maj_updated_at()', t);
    execute format('create trigger organisation_immuable before update on public.%I for each row execute function scolagrid.organisation_immuable()', t);
  end loop;
end $$;

-- Une période clôturée fige tout ce qui s'y rattache.
create or replace function scolagrid.periode_ouverte(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select statut = 'ouverte' from public.periodes_evaluation where id = p), false)
$$;
revoke all on function scolagrid.periode_ouverte(uuid) from public;

create or replace function scolagrid.periode_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.statut is distinct from old.statut then
    if new.statut = 'cloturee' then
      new.cloturee_par := auth.uid();
      new.cloturee_le := now();
    else
      -- Rouvrir une période clôturée : le fondateur seulement (bulletins déjà remis).
      if auth.uid() is not null and not exists (
           select 1 from public.rattachements where organisation_id = old.organisation_id and user_id = auth.uid()
             and actif and role = 'fondateur') then
        raise exception 'Rouvrir une période clôturée est réservé au fondateur' using errcode = '42501';
      end if;
      new.cloturee_par := null;
      new.cloturee_le := null;
    end if;
  end if;
  -- Le barème ne change plus dès qu'une note est saisie dans la période.
  if tg_op = 'UPDATE' and new.bareme <> old.bareme and exists (
       select 1 from public.notes n join public.evaluations e on e.id = n.evaluation_id where e.periode_id = old.id) then
    raise exception 'Des notes sont déjà saisies : le barème ne change plus' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger periode_controle before insert or update on public.periodes_evaluation
  for each row execute function scolagrid.periode_controle();
revoke all on function scolagrid.periode_controle() from public;

create or replace function scolagrid.evaluation_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.types_evaluation;
begin
  if not scolagrid.periode_ouverte(coalesce(new.periode_id, old.periode_id))
     or (tg_op = 'UPDATE' and not scolagrid.periode_ouverte(old.periode_id)) then
    raise exception 'Période clôturée : les évaluations sont figées' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' and auth.uid() is not null then new.cree_par := auth.uid(); end if;
  select * into t from public.types_evaluation where id = new.type_id;
  if t.unique_par_periode and exists (
       select 1 from public.evaluations e where e.periode_id = new.periode_id and e.classe_id = new.classe_id
         and e.matiere_id = new.matiere_id and e.type_id = new.type_id and e.id <> new.id) then
    raise exception '« % » : une seule par période et par matière', t.libelle using errcode = '23505';
  end if;
  return new;
end $$;
create trigger evaluation_controle before insert or update or delete on public.evaluations
  for each row execute function scolagrid.evaluation_controle();
revoke all on function scolagrid.evaluation_controle() from public;

create or replace function scolagrid.note_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.periodes_evaluation;
begin
  select pe.* into p from public.periodes_evaluation pe join public.evaluations e on e.periode_id = pe.id
  where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  -- Évaluation supprimée (ses notes partent avec elle) : déjà contrôlé sur l'évaluation.
  if tg_op = 'DELETE' and p.id is null then return old; end if;
  if p.statut is distinct from 'ouverte' then
    raise exception 'Période clôturée : les notes sont figées' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  new.bareme := p.bareme;
  if auth.uid() is not null then new.saisi_par := auth.uid(); end if;
  if new.etat <> 'note' then new.valeur := null; end if;
  if new.valeur is not null and new.valeur > p.bareme then
    raise exception 'Note supérieure au barème (sur %)', p.bareme using errcode = '23514';
  end if;
  return new;
end $$;
create trigger note_controle before insert or update or delete on public.notes
  for each row execute function scolagrid.note_controle();
revoke all on function scolagrid.note_controle() from public;

create or replace function scolagrid.appreciation_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not scolagrid.periode_ouverte(new.periode_id) then
    raise exception 'Période clôturée : appréciations figées' using errcode = '23514';
  end if;
  if auth.uid() is not null then new.par := auth.uid(); end if;
  return new;
end $$;
create trigger appreciation_controle before insert or update on public.appreciations
  for each row execute function scolagrid.appreciation_controle();
revoke all on function scolagrid.appreciation_controle() from public;

-- Règles d'accès.
grant select, insert, update on public.periodes_evaluation, public.types_evaluation to authenticated;
create policy "notes : lecture" on public.periodes_evaluation for select to authenticated using (scolagrid.lit_notes(organisation_id));
create policy "direction : périodes" on public.periodes_evaluation for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "direction : périodes (modif)" on public.periodes_evaluation for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')) with check (true);
create policy "notes : lecture" on public.types_evaluation for select to authenticated using (scolagrid.lit_notes(organisation_id));
create policy "direction : types" on public.types_evaluation for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "direction : types (modif)" on public.types_evaluation for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')) with check (true);

grant select, insert, update, delete on public.evaluations, public.notes to authenticated;
grant select, insert, update on public.appreciations to authenticated;
do $$ declare t text; begin
  foreach t in array array['evaluations', 'notes', 'appreciations'] loop
    execute format('create policy "notes : lecture" on public.%I for select to authenticated using (scolagrid.lit_notes(organisation_id))', t);
    execute format($p$create policy "saisie" on public.%I for insert to authenticated
      with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'saisir_notes')
                  or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'))$p$, t);
    execute format($p$create policy "saisie (modif)" on public.%I for update to authenticated
      using (scolagrid.a_le_droit_quelque_part(organisation_id, 'saisir_notes')
             or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')) with check (true)$p$, t);
  end loop;
end $$;
create policy "saisie (suppression)" on public.evaluations for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'saisir_notes')
         or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "saisie (suppression)" on public.notes for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'saisir_notes')
         or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));

alter publication powersync add table public.periodes_evaluation, public.types_evaluation, public.evaluations,
  public.notes, public.appreciations;
