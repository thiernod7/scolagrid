-- 045 : le calendrier des évaluations se prépare avant la session.
--
-- Une session a un calendrier :
--  - « libre » : chacun fixe ses dates quand il crée l'épreuve (comme avant) ;
--  - « preparation » : la direction (ou l'enseignant, pour ses matières) programme
--    les épreuves avant la date limite « programmation_avant » ;
--  - « publie » : la direction a validé ; les dates sont figées pour les enseignants
--    (seule la direction des études ajoute, déplace ou retire une épreuve). Une
--    épreuve déplacée après la publication garde sa date prévue.
-- L'épreuve porte en plus une heure et une durée (facultatives : compositions).
-- Partout : une note ne se saisit qu'à partir du jour de l'épreuve.
-- Les évaluations mensuelles suivent la règle de l'école (libres par défaut).

alter table public.sessions_evaluation
  add column calendrier text not null default 'libre' check (calendrier in ('libre', 'preparation', 'publie')),
  add column programmation_avant date,
  add column publie_le timestamptz,
  add column publie_par uuid references auth.users (id) on delete set null;

alter table public.evaluations
  add column date_prevue date,
  add column heure text check (heure is null or heure ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  add column duree_min integer check (duree_min is null or duree_min between 10 and 480);

alter table public.regles_notes
  add column calendrier_mensuel text not null default 'libre' check (calendrier_mensuel in ('libre', 'valide'));

-- La publication est datée ; elle fixe la date prévue de chaque épreuve.
create or replace function scolagrid.session_calendrier() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.calendrier is distinct from old.calendrier then
    if new.calendrier = 'publie' then
      new.publie_le := now();
      new.publie_par := auth.uid();
    else
      new.publie_le := null;
      new.publie_par := null;
    end if;
  end if;
  return new;
end $$;
create trigger session_calendrier before update on public.sessions_evaluation
  for each row execute function scolagrid.session_calendrier();

create or replace function scolagrid.apres_publication() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.calendrier = 'publie' and old.calendrier is distinct from 'publie' then
    update public.evaluations set date_prevue = date_evaluation, updated_at = now()
    where session_id = new.id and date_prevue is null;
  end if;
  return null;
end $$;
create trigger apres_publication after update on public.sessions_evaluation
  for each row execute function scolagrid.apres_publication();
revoke all on function scolagrid.session_calendrier(), scolagrid.apres_publication() from public;

-- Les contrôles des épreuves, avec le calendrier publié.
create or replace function scolagrid.evaluation_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t public.types_evaluation; s public.sessions_evaluation; seulement_remise boolean; direction boolean;
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
  -- Calendrier publié : l'enseignant n'ajoute, ne déplace ni ne retire d'épreuve.
  direction := auth.uid() is null
    or scolagrid.a_le_droit_quelque_part(coalesce(new.organisation_id, old.organisation_id), 'planifier_evaluations');
  if not direction and (
       (tg_op in ('UPDATE', 'DELETE') and exists (select 1 from public.sessions_evaluation where id = old.session_id and calendrier = 'publie'))
       or (tg_op in ('INSERT', 'UPDATE') and exists (select 1 from public.sessions_evaluation where id = new.session_id and calendrier = 'publie')
           and (tg_op = 'INSERT' or new.date_evaluation is distinct from old.date_evaluation or new.heure is distinct from old.heure
                or new.duree_min is distinct from old.duree_min or new.session_id is distinct from old.session_id))) then
    raise exception 'Calendrier publié : seule la direction ajoute, déplace ou retire une épreuve' using errcode = '42501';
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
    -- Publiée : la date prévue reste celle du calendrier, même si l'épreuve est déplacée.
    if s.calendrier = 'publie' then
      if tg_op = 'INSERT' then
        new.date_prevue := coalesce(new.date_prevue, new.date_evaluation);
      elsif new.date_prevue is null then
        new.date_prevue := old.date_evaluation;
      end if;
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

-- Les notes : à partir du jour de l'épreuve seulement.
create or replace function scolagrid.note_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.periodes_evaluation; sess uuid; jour date;
begin
  select pe.* into p from public.periodes_evaluation pe join public.evaluations e on e.periode_id = pe.id
  where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  select e.session_id, e.date_evaluation into sess, jour from public.evaluations e where e.id = coalesce(new.evaluation_id, old.evaluation_id);
  if tg_op = 'DELETE' and p.id is null then return old; end if;
  if p.statut is distinct from 'ouverte' then
    raise exception 'Période clôturée : les notes sont figées' using errcode = '23514';
  end if;
  if not scolagrid.session_ouverte(sess) and (tg_op = 'DELETE' or new.motif is null) then
    raise exception 'Session clôturée : une correction demande un motif' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if jour > current_date then
    raise exception 'Épreuve du % : les notes se saisissent à partir de ce jour', to_char(jour, 'DD/MM') using errcode = '23514';
  end if;
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
