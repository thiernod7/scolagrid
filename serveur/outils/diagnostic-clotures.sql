-- Diagnostic des clôtures de caisse, SANS RIEN MODIFIER. N'affiche que des nombres :
-- ni noms, ni montants. L'encaisseur est désigné par une lettre (A, B…) et sa fonction.
\set ON_ERROR_STOP on
begin transaction read only;

with qui as (
  select r.user_id, r.organisation_id, string_agg(distinct r.role, '+') as fonction
  from public.rattachements r where r.actif group by 1, 2
), recus as (
  select e.organisation_id, e.site_id, e.encaisse_par, e.jour_caisse as jour,
         count(*) filter (where e.statut = 'valide') as valides,
         count(*) filter (where e.statut = 'annule') as annules,
         count(*) filter (where e.apres_cloture) as apres_cloture,
         count(*) filter (where e.jour_caisse <> e.date_effective) as autre_date_effective,
         max(e.recu_serveur_le) as dernier_recu
  from public.encaissements e
  where e.jour_caisse >= current_date - 10
  group by 1, 2, 3, 4
), clos as (
  select c.organisation_id, c.site_id, c.encaisse_par, c.jour, count(*) as clotures,
         sum(c.nb_recus) as recus_clotures, min(c.created_at) as premiere, max(c.created_at) as derniere
  from public.clotures_caisse c where c.jour >= current_date - 10 group by 1, 2, 3, 4
)
select dense_rank() over (order by coalesce(r.organisation_id, k.organisation_id)) as ecole,
       chr(64 + dense_rank() over (partition by coalesce(r.organisation_id, k.organisation_id)
                                   order by coalesce(r.encaisse_par, k.encaisse_par))::int) as encaisseur,
       q.fonction,
       to_char(coalesce(r.jour, k.jour), 'DD/MM') as jour,
       coalesce(r.valides, 0) as recus_valides, coalesce(r.annules, 0) as annules,
       coalesce(r.apres_cloture, 0) as apres_cloture, coalesce(r.autre_date_effective, 0) as payes_autre_jour,
       coalesce(k.clotures, 0) as clotures, coalesce(k.recus_clotures, 0) as recus_dans_clotures,
       coalesce(r.valides, 0) - coalesce(k.recus_clotures, 0) as reste_a_clore,
       to_char(k.derniere at time zone 'UTC', 'DD/MM HH24:MI') as derniere_cloture,
       to_char(r.dernier_recu at time zone 'UTC', 'DD/MM HH24:MI') as dernier_recu_serveur
from recus r
full join clos k on k.organisation_id = r.organisation_id and k.site_id = r.site_id
                and k.encaisse_par = r.encaisse_par and k.jour = r.jour
left join qui q on q.user_id = coalesce(r.encaisse_par, k.encaisse_par) and q.organisation_id = coalesce(r.organisation_id, k.organisation_id)
order by 1, 4, 2;
rollback;
