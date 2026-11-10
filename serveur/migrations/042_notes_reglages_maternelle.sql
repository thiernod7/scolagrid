-- 042 : notes et bulletins (lot 3) — maternelle par acquis, mentions par cycle,
-- traitement de l'absence au choix de l'école.
--
-- Maternelle (spécification §5.5) : on observe des acquis (acquis / en cours
-- d'acquisition / non acquis), sans chiffre, ni moyenne, ni rang. Le barème d'une
-- période a donc une nature : numérique (sur 10, sur 20) ou appréciations.
-- Mentions (§8.6) : seuils configurables par cycle, dans le barème du cycle,
-- « Insuffisant » compris. Absences (§5.7) : justifié exclu / non justifié 0
-- (défaut), toujours 0, ou toujours exclu.

alter table public.periodes_evaluation add column nature text not null default 'numerique'
  check (nature in ('numerique', 'appreciations'));
-- Les périodes de maternelle passent aux acquis (sauf si des notes chiffrées y sont déjà).
update public.periodes_evaluation p set nature = 'appreciations'
where p.cycle = 'maternelle' and not exists (
  select 1 from public.notes n join public.evaluations e on e.id = n.evaluation_id where e.periode_id = p.id and n.valeur is not null);

alter table public.notes add column acquis text check (acquis is null or acquis in ('acquis', 'en_cours', 'non_acquis'));
-- « Une note a une valeur » devient : une valeur (numérique) ou un acquis (maternelle).
alter table public.notes drop constraint notes_check;
alter table public.notes add constraint notes_valeur_ou_acquis check (etat <> 'note' or valeur is not null or acquis is not null);

-- La nature et le barème ne changent plus dès qu'une note est saisie dans la période.
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
  if tg_op = 'UPDATE' and (new.bareme <> old.bareme or new.nature <> old.nature) and exists (
       select 1 from public.notes n join public.evaluations e on e.id = n.evaluation_id where e.periode_id = old.id) then
    raise exception 'Des notes sont déjà saisies : le barème ne change plus' using errcode = '23514';
  end if;
  return new;
end $$;

-- Une note suit la nature de sa période : un chiffre, ou un acquis.
create or replace function scolagrid.note_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.periodes_evaluation; sess uuid;
begin
  select pe.* into p from public.periodes_evaluation pe join public.evaluations e on e.periode_id = pe.id
  where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  select e.session_id into sess from public.evaluations e where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  if tg_op = 'DELETE' and p.id is null then return old; end if;
  if p.statut is distinct from 'ouverte' then
    raise exception 'Période clôturée : les notes sont figées' using errcode = '23514';
  end if;
  if not scolagrid.session_ouverte(sess) then
    raise exception 'Session clôturée : les notes sont figées (rouvrez la session pour corriger)' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  new.bareme := p.bareme;
  if auth.uid() is not null then new.saisi_par := auth.uid(); end if;
  if new.etat <> 'note' then
    new.valeur := null;
    new.acquis := null;
  elsif p.nature = 'appreciations' then
    new.valeur := null;
    if new.acquis is null then
      raise exception 'Maternelle : choisissez acquis, en cours ou non acquis' using errcode = '23514';
    end if;
  else
    new.acquis := null;
    if new.valeur is null then
      raise exception 'Note manquante' using errcode = '23514';
    end if;
    if new.valeur > p.bareme then
      raise exception 'Note supérieure au barème (sur %)', p.bareme using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

-- Les règles de calcul de l'école (une ligne par école).
create table public.regles_notes (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null unique references public.organisations (id) on delete cascade,
  absences text not null default 'justifie_exclu' check (absences in ('justifie_exclu', 'toujours_zero', 'toujours_exclu')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Les mentions de chaque cycle, dans son barème. Sans ligne pour un cycle : les
-- seuils par défaut (16, 14, 12, 10 sur 20 ; 8, 7, 6, 5 sur 10 ; Insuffisant en dessous).
create table public.mentions_notes (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  cycle text not null check (length(trim(cycle)) between 2 and 40),
  minimum numeric(6, 2) not null check (minimum >= 0 and minimum <= 100),
  libelle text not null check (length(trim(libelle)) between 2 and 40),
  ordre integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, cycle, minimum)
);

do $$ declare t text; begin
  foreach t in array array['regles_notes', 'mentions_notes'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I for each row execute function scolagrid.maj_updated_at()', t);
    execute format('create trigger organisation_immuable before update on public.%I for each row execute function scolagrid.organisation_immuable()', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy "notes : lecture" on public.%I for select to authenticated using (scolagrid.lit_notes(organisation_id))', t);
    execute format($p$create policy "direction : ajout" on public.%I for insert to authenticated
      with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'))$p$, t);
    execute format($p$create policy "direction : modif" on public.%I for update to authenticated
      using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')) with check (true)$p$, t);
    execute format($p$create policy "direction : suppression" on public.%I for delete to authenticated
      using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'))$p$, t);
  end loop;
end $$;

alter publication powersync add table public.regles_notes, public.mentions_notes;
