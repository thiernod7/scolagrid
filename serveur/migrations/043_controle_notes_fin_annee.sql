-- 043 : notes et bulletins — lot 4 (contrôle des notes) et lot 5 (fin d'année).
--
-- Lot 4 :
-- * Toute modification d'une note est tracée (ancienne et nouvelle valeur, auteur,
--   date) ; on ne supprime pas sans trace. Une session clôturée (période encore
--   ouverte) accepte une correction seulement avec un motif, gardé dans l'historique.
-- * La remise des notes : l'enseignant déclare sa saisie terminée. Ce n'est pas un
--   verrou, c'est un indicateur ; un délai après l'épreuve (15 jours par défaut)
--   fait remonter les retards à la direction, sans bloquer.
-- Lot 5 : fin d'année. La moyenne annuelle (simple, ou la dernière période pesant
-- plus) propose Admis ou Redouble selon le seuil du barème (5 sur 10, 10 sur 20) ;
-- le conseil décide (admis, redouble, admis par décision du conseil — motif
-- obligatoire —, exclu, orienté). La décision alimente la réinscription.

-- Lot 4 : historique ----------------------------------------------------------
alter table public.notes add column motif text check (motif is null or length(trim(motif)) between 3 and 200);

create table public.notes_historique (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  note_id uuid not null,
  evaluation_id uuid not null,
  eleve_id uuid not null,
  avant_valeur numeric(6, 2),
  avant_etat text,
  avant_acquis text,
  apres_valeur numeric(6, 2),
  apres_etat text,
  apres_acquis text,
  motif text,
  par uuid references auth.users (id) on delete set null,
  le timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index notes_historique_note_idx on public.notes_historique (evaluation_id, eleve_id);

-- Remise des notes et délai de remise.
alter table public.evaluations add column remise_le timestamptz;
alter table public.evaluations add column remise_par uuid references auth.users (id) on delete set null;
alter table public.regles_notes add column delai_remise_jours integer not null default 15 check (delai_remise_jours between 1 and 90);

-- Lot 5 : règles de fin d'année -----------------------------------------------
alter table public.regles_notes add column moyenne_annuelle text not null default 'simple' check (moyenne_annuelle in ('simple', 'ponderee'));
alter table public.regles_notes add column poids_derniere integer not null default 2 check (poids_derniere between 1 and 5);
-- Seuils de passage, dans le barème : 5 sur 10 (primaire), 10 sur 20 (collège, lycée).
alter table public.regles_notes add column seuil_passage_10 numeric(4, 2) not null default 5 check (seuil_passage_10 between 0 and 10);
alter table public.regles_notes add column seuil_passage_20 numeric(4, 2) not null default 10 check (seuil_passage_20 between 0 and 20);

create table public.decisions_annee (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  annee_id uuid not null references public.annees_scolaires (id) on delete cascade,
  inscription_id uuid not null references public.inscriptions (id) on delete cascade,
  eleve_id uuid not null references public.eleves (id) on delete cascade,
  moyenne_annuelle numeric(6, 2),
  proposition text check (proposition is null or proposition in ('admis', 'redouble')),
  decision text not null check (decision in ('admis', 'redouble', 'admis_conseil', 'exclu', 'oriente')),
  motif text check (motif is null or length(trim(motif)) between 3 and 300),
  par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (inscription_id),
  -- « Admis par décision du conseil » garde la trace qu'on s'écarte du calcul : motif obligatoire.
  check (decision <> 'admis_conseil' or motif is not null)
);

do $$ declare t text; begin
  foreach t in array array['notes_historique', 'decisions_annee'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I for each row execute function scolagrid.maj_updated_at()', t);
    execute format('create trigger organisation_immuable before update on public.%I for each row execute function scolagrid.organisation_immuable()', t);
    execute format('create policy "notes : lecture" on public.%I for select to authenticated using (scolagrid.lit_notes(organisation_id))', t);
  end loop;
end $$;
-- L'historique ne s'écrit que par le serveur (déclencheur) : lecture seule pour tous.
grant select on public.notes_historique to authenticated;
-- Les décisions : la direction (planifier_evaluations).
grant select, insert, update, delete on public.decisions_annee to authenticated;
create policy "direction : décision" on public.decisions_annee for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "direction : décision (modif)" on public.decisions_annee for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations')) with check (true);
create policy "direction : décision (suppression)" on public.decisions_annee for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));

create or replace function scolagrid.decision_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then new.par := auth.uid(); end if;
  select i.eleve_id, i.annee_id into new.eleve_id, new.annee_id from public.inscriptions i where i.id = new.inscription_id;
  return new;
end $$;
create trigger decision_controle before insert or update on public.decisions_annee
  for each row execute function scolagrid.decision_controle();
revoke all on function scolagrid.decision_controle() from public;

alter publication powersync add table public.notes_historique, public.decisions_annee;

-- Les notes : session close → correction seulement avec motif ; toute modification tracée.
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
  if not scolagrid.session_ouverte(sess) and (tg_op = 'DELETE' or new.motif is null) then
    raise exception 'Session clôturée : une correction demande un motif' using errcode = '23514';
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

create or replace function scolagrid.note_historique() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and (new.valeur, new.etat, new.acquis) is not distinct from (old.valeur, old.etat, old.acquis) then
    return null;
  end if;
  insert into public.notes_historique (organisation_id, note_id, evaluation_id, eleve_id, avant_valeur, avant_etat, avant_acquis,
                                       apres_valeur, apres_etat, apres_acquis, motif, par)
  values (old.organisation_id, old.id, old.evaluation_id, old.eleve_id, old.valeur, old.etat, old.acquis,
          case when tg_op = 'UPDATE' then new.valeur end, case when tg_op = 'UPDATE' then new.etat else 'supprimee' end,
          case when tg_op = 'UPDATE' then new.acquis end,
          case when tg_op = 'UPDATE' then new.motif end, auth.uid());
  return null;
end $$;
create trigger note_historique after update or delete on public.notes
  for each row execute function scolagrid.note_historique();
revoke all on function scolagrid.note_historique() from public;

-- La remise et le motif ne sont pas des épreuves figées : l'enseignant remet même
-- après la clôture de la session (indicateur, pas verrou).
create or replace function scolagrid.evaluation_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.types_evaluation; s public.sessions_evaluation; seulement_remise boolean;
begin
  seulement_remise := tg_op = 'UPDATE'
    and (to_jsonb(new) - 'remise_le' - 'remise_par' - 'updated_at') = (to_jsonb(old) - 'remise_le' - 'remise_par' - 'updated_at');
  if seulement_remise then
    if new.remise_le is not null and old.remise_le is null then
      new.remise_par := auth.uid();
    end if;
    return new;
  end if;
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
