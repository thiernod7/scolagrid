-- 024 : cycle de vie de l'année scolaire.
--
-- En préparation → inscriptions ouvertes → en cours → clôturée, sans retour en
-- arrière, et jamais deux années en cours. « en_cours » suit l'état (les
-- écrans qui lisent l'année en cours ne changent pas).
-- Une année en préparation ne reçoit pas d'inscription. Une année clôturée est
-- en lecture seule (classes, frais, échéances, calendrier, inscriptions), mais
-- ses arriérés s'encaissent toujours et le statut d'un élève (diplômé…) peut
-- encore être noté.

alter table public.annees_scolaires
  add column etat text not null default 'preparation'
    check (etat in ('preparation', 'inscriptions', 'en_cours', 'cloturee')),
  add column cloturee_le timestamptz;

update public.annees_scolaires
  set etat = case when en_cours then 'en_cours' when fin < current_date then 'cloturee' else 'preparation' end,
      cloturee_le = case when not en_cours and fin < current_date then now() end;

create or replace function scolagrid.rang_etat(e text) returns integer
language sql immutable set search_path = '' as $$
  select case e when 'preparation' then 1 when 'inscriptions' then 2 when 'en_cours' then 3 else 4 end
$$;

create or replace function scolagrid.annee_cycle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare autre text;
begin
  if tg_op = 'INSERT' then
    -- Les postes qui ne connaissent que « en_cours » restent compris.
    if new.en_cours then new.etat := 'en_cours'; end if;
    if new.etat = 'cloturee' then
      raise exception 'Une année ne se crée pas clôturée' using errcode = '23514';
    end if;
  else
    if new.etat = old.etat and new.en_cours is distinct from old.en_cours then
      new.etat := case when new.en_cours then 'en_cours' else 'cloturee' end;
    end if;
    if scolagrid.rang_etat(new.etat) < scolagrid.rang_etat(old.etat) then
      raise exception 'Une année ne revient pas en arrière (% → %)', old.etat, new.etat using errcode = '23514';
    end if;
    if old.etat = 'cloturee' and (new.libelle, new.debut, new.fin, new.periodicite, new.nb_mois)
         is distinct from (old.libelle, old.debut, old.fin, old.periodicite, old.nb_mois) then
      raise exception 'Une année clôturée ne se modifie plus' using errcode = '23514';
    end if;
    if new.etat = 'cloturee' and old.etat <> 'cloturee' then new.cloturee_le := now(); end if;
    if new.etat <> 'cloturee' then new.cloturee_le := null; end if;
  end if;
  if new.etat = 'en_cours' and (tg_op = 'INSERT' or old.etat <> 'en_cours') then
    select libelle into autre from public.annees_scolaires
      where organisation_id = new.organisation_id and etat = 'en_cours' and id <> new.id;
    if autre is not null then
      raise exception 'L''année % est encore en cours : clôturez-la d''abord', autre using errcode = '23505';
    end if;
  end if;
  new.en_cours := new.etat = 'en_cours';
  return new;
end $$;
revoke all on function scolagrid.annee_cycle() from public;
create trigger annee_cycle before insert or update on public.annees_scolaires
  for each row execute function scolagrid.annee_cycle();

-- Lecture seule des années clôturées ---------------------------------------------------

create or replace function scolagrid.etat_annee(annee uuid) returns text
language sql stable security definer set search_path = '' as $$
  select etat from public.annees_scolaires where id = annee
$$;
revoke all on function scolagrid.etat_annee(uuid) from public;

-- Classes, frais, calendrier : rien ne bouge dans une année clôturée. (Les suppressions
-- restent aux clés étrangères : une classe ou un frais utilisé ne se supprime pas.)
create or replace function scolagrid.annee_ouverte() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  a uuid;
  avant uuid;
begin
  if tg_table_name = 'echeances' then
    select annee_id into a from public.frais where id = new.frais_id;
    if tg_op = 'UPDATE' then select annee_id into avant from public.frais where id = old.frais_id; end if;
  else
    a := new.annee_id;
    if tg_op = 'UPDATE' then avant := old.annee_id; end if;
  end if;
  if scolagrid.etat_annee(a) = 'cloturee' or scolagrid.etat_annee(avant) = 'cloturee' then
    raise exception 'Cette année scolaire est clôturée : elle ne se modifie plus' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function scolagrid.annee_ouverte() from public;
do $$
declare t text;
begin
  foreach t in array array['classes', 'frais', 'tranches_annee', 'echeances'] loop
    execute format('create trigger annee_ouverte before insert or update on public.%I
                    for each row execute function scolagrid.annee_ouverte()', t);
  end loop;
end $$;

-- Inscriptions : pas dans une année en préparation ni clôturée ; dans une année
-- clôturée, seuls le statut, le motif et la date de sortie changent encore.
create or replace function scolagrid.inscription_selon_annee() returns trigger
language plpgsql security definer set search_path = '' as $$
declare e text := scolagrid.etat_annee(new.annee_id);
begin
  if tg_op = 'INSERT' then
    if e = 'preparation' then
      raise exception 'Les inscriptions de cette année ne sont pas encore ouvertes' using errcode = '23514';
    elsif e = 'cloturee' then
      raise exception 'Cette année scolaire est clôturée' using errcode = '23514';
    end if;
  elsif e = 'cloturee' and (new.classe_id, new.site_id, new.date_effective, new.arrivee_mode, new.arrivee_retrait_gnf)
          is distinct from (old.classe_id, old.site_id, old.date_effective, old.arrivee_mode, old.arrivee_retrait_gnf) then
    raise exception 'Cette année scolaire est clôturée : seul le statut de l''élève peut encore changer' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function scolagrid.inscription_selon_annee() from public;
create trigger inscription_selon_annee before insert or update on public.inscriptions
  for each row execute function scolagrid.inscription_selon_annee();
