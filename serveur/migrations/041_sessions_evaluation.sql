-- 041 : notes et bulletins (lot 2) — les sessions d'évaluation.
--
-- Trois niveaux, pas deux : période → session → épreuve. Une session est une
-- fenêtre nommée de la période (« Évaluation d'octobre », du 05/10 au 07/11), d'un
-- type (Évaluation, Composition, Examen blanc), ouverte ou clôturée. Une épreuve
-- appartient à sa session, pas à sa date : celle d'octobre passée le 5 novembre
-- reste d'octobre. Chaque session a ses moyennes, son classement et son bulletin
-- (mensuel) ; la moyenne de période repart toujours de toutes les notes.
-- Deux clôtures emboîtées : la session fige ses notes, la période fige tout.
-- Une épreuve sans session (rare) se rattache directement à la période.

create table public.sessions_evaluation (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  periode_id uuid not null references public.periodes_evaluation (id) on delete cascade,
  type_id uuid not null references public.types_evaluation (id) on delete restrict,
  libelle text not null check (length(trim(libelle)) between 2 and 80),
  debut date not null,
  fin date not null check (fin >= debut),
  ordre integer not null default 0,
  epreuves_attendues integer check (epreuves_attendues is null or epreuves_attendues between 1 and 10),
  statut text not null default 'ouverte' check (statut in ('ouverte', 'cloturee')),
  cloturee_par uuid references auth.users (id) on delete set null,
  cloturee_le timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index sessions_evaluation_periode_idx on public.sessions_evaluation (periode_id, debut);

alter table public.evaluations add column session_id uuid references public.sessions_evaluation (id) on delete restrict;
create index evaluations_session_idx on public.evaluations (session_id);

alter table public.sessions_evaluation owner to postgres;
alter table public.sessions_evaluation replica identity full;
alter table public.sessions_evaluation enable row level security;
revoke all on public.sessions_evaluation from anon, authenticated;
grant select on public.sessions_evaluation to powersync_role;
create trigger maj_updated_at before update on public.sessions_evaluation for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.sessions_evaluation for each row execute function scolagrid.organisation_immuable();

-- Une session vit dans sa période (dates comprises), et suit sa clôture.
create or replace function scolagrid.session_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.periodes_evaluation;
begin
  select * into p from public.periodes_evaluation where id = coalesce(new.periode_id, old.periode_id);
  if tg_op = 'DELETE' then
    if p.statut <> 'ouverte' then
      raise exception 'Période clôturée : les sessions sont figées' using errcode = '23514';
    end if;
    return old;
  end if;
  if p.statut <> 'ouverte' then
    raise exception 'Période clôturée : les sessions sont figées' using errcode = '23514';
  end if;
  if new.debut < p.debut or new.fin > p.fin then
    raise exception 'La session doit rester dans la période (du % au %)', to_char(p.debut, 'DD/MM/YYYY'), to_char(p.fin, 'DD/MM/YYYY')
      using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.periode_id <> old.periode_id then
    raise exception 'Une session ne change pas de période' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.type_id <> old.type_id and exists (select 1 from public.evaluations where session_id = old.id) then
    raise exception 'Des épreuves sont dans la session : son type ne change plus' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and (new.debut <> old.debut or new.fin <> old.fin) and exists (
       select 1 from public.evaluations where session_id = old.id and (date_evaluation < new.debut or date_evaluation > new.fin)) then
    raise exception 'Des épreuves tomberaient hors de la fenêtre : déplacez-les d''abord' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and new.statut is distinct from old.statut then
    if new.statut = 'cloturee' then
      new.cloturee_par := auth.uid();
      new.cloturee_le := now();
    else
      new.cloturee_par := null;
      new.cloturee_le := null;
    end if;
  end if;
  return new;
end $$;
create trigger session_controle before insert or update or delete on public.sessions_evaluation
  for each row execute function scolagrid.session_controle();
revoke all on function scolagrid.session_controle() from public;

create or replace function scolagrid.session_ouverte(s uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select s is null or coalesce((select statut = 'ouverte' from public.sessions_evaluation where id = s), false)
$$;
revoke all on function scolagrid.session_ouverte(uuid) from public;

-- L'épreuve suit sa session : même période, type de la session, date dans la fenêtre.
create or replace function scolagrid.evaluation_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.types_evaluation; s public.sessions_evaluation;
begin
  if not scolagrid.periode_ouverte(coalesce(new.periode_id, old.periode_id))
     or (tg_op = 'UPDATE' and not scolagrid.periode_ouverte(old.periode_id)) then
    raise exception 'Période clôturée : les évaluations sont figées' using errcode = '23514';
  end if;
  if tg_op in ('UPDATE', 'DELETE') and not scolagrid.session_ouverte(old.session_id) then
    raise exception 'Session clôturée : ses épreuves sont figées' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' and auth.uid() is not null then new.cree_par := auth.uid(); end if;
  if new.session_id is not null then
    select * into s from public.sessions_evaluation where id = new.session_id;
    if s.periode_id <> new.periode_id then
      raise exception 'La session n''est pas dans cette période' using errcode = '23514';
    end if;
    if s.statut <> 'ouverte' then
      raise exception 'Session clôturée : ses épreuves sont figées' using errcode = '23514';
    end if;
    new.type_id := s.type_id;
    if new.date_evaluation < s.debut or new.date_evaluation > s.fin then
      raise exception 'Date hors de la session « % » (du % au %)', s.libelle, to_char(s.debut, 'DD/MM'), to_char(s.fin, 'DD/MM')
        using errcode = '23514';
    end if;
  end if;
  select * into t from public.types_evaluation where id = new.type_id;
  if t.unique_par_periode and exists (
       select 1 from public.evaluations e where e.periode_id = new.periode_id and e.classe_id = new.classe_id
         and e.matiere_id = new.matiere_id and e.type_id = new.type_id and e.id <> new.id) then
    raise exception '« % » : une seule par période et par matière', t.libelle using errcode = '23505';
  end if;
  return new;
end $$;

-- Une session clôturée fige ses notes (la période, elle, fige tout).
create or replace function scolagrid.note_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.periodes_evaluation; sess uuid;
begin
  select pe.* into p from public.periodes_evaluation pe join public.evaluations e on e.periode_id = pe.id
  where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  select e.session_id into sess from public.evaluations e where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  -- Évaluation supprimée (ses notes partent avec elle) : déjà contrôlé sur l'évaluation.
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
  if new.etat <> 'note' then new.valeur := null; end if;
  if new.valeur is not null and new.valeur > p.bareme then
    raise exception 'Note supérieure au barème (sur %)', p.bareme using errcode = '23514';
  end if;
  return new;
end $$;

-- Règles d'accès : comme les périodes (planifier_evaluations).
grant select, insert, update, delete on public.sessions_evaluation to authenticated;
create policy "notes : lecture" on public.sessions_evaluation for select to authenticated using (scolagrid.lit_notes(organisation_id));
create policy "direction : sessions" on public.sessions_evaluation for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "direction : sessions (modif)" on public.sessions_evaluation for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')) with check (true);
create policy "direction : sessions (suppression)" on public.sessions_evaluation for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));

alter publication powersync add table public.sessions_evaluation;

-- Les sessions par défaut d'une période : une « Évaluation de <mois> » par mois,
-- puis la composition sur les deux dernières semaines. Même découpage que l'app.
create or replace function scolagrid.sessions_par_defaut(per uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p public.periodes_evaluation;
  t_eval uuid; t_compo uuid;
  mois text[] := array['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  debut_compo date; curseur date; fin_mois date; n integer := 0; nom text;
begin
  select * into p from public.periodes_evaluation where id = per;
  if p.id is null or exists (select 1 from public.sessions_evaluation where periode_id = per) then return; end if;
  select id into t_eval from public.types_evaluation where organisation_id = p.organisation_id and actif and libelle = 'Évaluation';
  select id into t_compo from public.types_evaluation where organisation_id = p.organisation_id and actif and libelle = 'Composition';
  if t_eval is null then return; end if;
  debut_compo := case when t_compo is not null and p.fin - p.debut >= 40 then p.fin - 13 else p.fin + 1 end;
  curseur := p.debut;
  while curseur < debut_compo loop
    fin_mois := least((date_trunc('month', curseur) + interval '1 month - 1 day')::date, debut_compo - 1);
    -- Un reste de moins d'une semaine rejoint le mois précédent.
    if n > 0 and fin_mois - curseur < 6 and fin_mois = debut_compo - 1 then
      update public.sessions_evaluation set fin = fin_mois where periode_id = per and ordre = n;
      exit;
    end if;
    nom := mois[extract(month from curseur)::int];
    n := n + 1;
    insert into public.sessions_evaluation (organisation_id, periode_id, type_id, libelle, debut, fin, ordre)
    values (p.organisation_id, per, t_eval,
            'Évaluation ' || case when left(nom, 1) in ('a', 'o') then 'd''' else 'de ' end || nom, curseur, fin_mois, n);
    curseur := fin_mois + 1;
  end loop;
  if debut_compo <= p.fin then
    insert into public.sessions_evaluation (organisation_id, periode_id, type_id, libelle, debut, fin, ordre)
    values (p.organisation_id, per, t_compo, 'Composition du ' || lower(p.libelle), debut_compo, p.fin, n + 1);
  end if;
end $$;
revoke all on function scolagrid.sessions_par_defaut(uuid) from public;

-- Les périodes existantes reçoivent leurs sessions ; chaque épreuve rejoint la
-- session de même type qui couvre sa date (sinon elle reste « hors session »).
do $$ declare r record; begin
  for r in select id from public.periodes_evaluation where statut = 'ouverte' loop
    perform scolagrid.sessions_par_defaut(r.id);
  end loop;
  update public.evaluations e set session_id = s.id
  from public.sessions_evaluation s
  where e.session_id is null and s.periode_id = e.periode_id and s.type_id = e.type_id
    and e.date_evaluation between s.debut and s.fin
    and scolagrid.periode_ouverte(e.periode_id);
end $$;
