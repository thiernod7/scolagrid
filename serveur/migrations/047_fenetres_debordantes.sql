-- 047 : les évaluations du mois débordent sur le mois suivant.
-- « Évaluation d'octobre » est une étiquette, pas le calendrier : elle peut se passer
-- jusqu'au 7 novembre (spécification Notes & bulletins §4.2). Les sessions proposées
-- par défaut vont donc du 8 d'un mois au 7 du suivant (la première commence avec la
-- période, la dernière s'arrête la veille de la composition). Les sessions existantes
-- ne changent pas : seules les nouvelles périodes en profitent. Même découpage que
-- l'app (_sessionsParDefaut).

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
    -- Jusqu'au 7 du mois suivant, sans empiéter sur la composition.
    fin_mois := least((date_trunc('month', curseur) + interval '1 month 6 days')::date, debut_compo - 1);
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
