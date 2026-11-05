-- Comptage SANS RIEN MODIFIER : reçus et dépenses rangés dans la caisse de leur
-- date effective alors qu'ils ont été saisis un autre jour. N'affiche que des
-- nombres (le journal est public) : ni noms, ni montants.
\set ON_ERROR_STOP on
begin transaction read only;

with r as (
  select e.organisation_id, e.site_id, e.encaisse_par as qui, e.statut,
         coalesce((to_jsonb(e) ->> 'jour_caisse')::date, e.date_effective) as actuel,
         (e.created_at at time zone 'UTC')::date as saisie
  from public.encaissements e
), c as (
  select r.*,
    case
      when r.saisie = r.actuel then '1. déjà au bon jour'
      when r.saisie > current_date or r.saisie < r.actuel then '5. date de saisie impossible : à corriger à la main'
      when exists (select 1 from public.clotures_caisse k where k.organisation_id = r.organisation_id and k.site_id = r.site_id
                   and k.encaisse_par = r.qui and k.jour = r.actuel) then '3. laissé : sa journée est clôturée'
      when exists (select 1 from public.clotures_caisse k where k.organisation_id = r.organisation_id and k.site_id = r.site_id
                   and k.encaisse_par = r.qui and k.jour = r.saisie) then '4. laissé : le jour de saisie est clôturé'
      else '2. à déplacer au jour de saisie'
    end as cas
  from r
)
select 'Reçus' as quoi, cas, count(*) as nombre,
       count(*) filter (where statut = 'valide') as dont_valides,
       count(distinct organisation_id) as ecoles
from c group by cas order by cas;

with d as (
  select d.organisation_id, d.site_id, d.sortie_par as qui, d.sortie_le as actuel,
         (d.created_at at time zone 'UTC')::date as saisie
  from public.depenses d where d.statut = 'sortie' and d.sortie_le is not null
), c as (
  select d.*,
    case
      when d.saisie = d.actuel then '1. déjà au bon jour'
      when d.saisie > current_date then '5. date de saisie impossible : à corriger à la main'
      when exists (select 1 from public.clotures_caisse k where k.organisation_id = d.organisation_id and k.site_id = d.site_id
                   and k.encaisse_par = d.qui and k.jour = d.actuel) then '3. laissé : sa journée est clôturée'
      when exists (select 1 from public.clotures_caisse k where k.organisation_id = d.organisation_id and k.site_id = d.site_id
                   and k.encaisse_par = d.qui and k.jour = d.saisie) then '4. laissé : le jour de saisie est clôturé'
      else '2. à déplacer au jour de saisie'
    end as cas
  from d
)
select 'Dépenses sorties' as quoi, cas, count(*) as nombre, count(distinct organisation_id) as ecoles
from c group by cas order by cas;

-- Écart entre date effective et saisie, pour les reçus (en jours) : ordre de grandeur.
select 'Reçus : écart saisie - date effective' as quoi,
       count(*) filter (where (created_at at time zone 'UTC')::date - date_effective between 1 and 3) as de_1_a_3_jours,
       count(*) filter (where (created_at at time zone 'UTC')::date - date_effective between 4 and 15) as de_4_a_15_jours,
       count(*) filter (where (created_at at time zone 'UTC')::date - date_effective > 15) as plus_de_15_jours
from public.encaissements;
rollback;
