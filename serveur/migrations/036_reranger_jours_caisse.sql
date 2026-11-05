-- 036 : reçus et dépenses enregistrés avant la version 0.9.17.
--
-- Ils étaient rangés dans la caisse de leur DATE EFFECTIVE. On les remet dans la
-- caisse du jour où ils ont été SAISIS (date de création), mais seulement si ni
-- leur journée actuelle ni le jour de saisie n'est clôturé : une journée close ne
-- bouge jamais. La date effective (celle du reçu) ne change pas.
-- Une date de saisie impossible (dans le futur, ou avant le paiement) n'est pas
-- touchée : la direction corrige ces reçus à la main (« Corriger la date »).

alter table public.encaissements disable trigger user;
update public.encaissements e
   set jour_caisse = (e.created_at at time zone 'UTC')::date
 where (e.created_at at time zone 'UTC')::date > e.jour_caisse
   and (e.created_at at time zone 'UTC')::date <= current_date
   and e.recu_serveur_le is not distinct from e.created_at   -- reçus d'avant la 0.9.17 (repris par la 035)
   and not exists (select 1 from public.clotures_caisse k
                   where k.organisation_id = e.organisation_id and k.site_id = e.site_id and k.encaisse_par = e.encaisse_par
                     and k.jour in (e.jour_caisse, (e.created_at at time zone 'UTC')::date));
alter table public.encaissements enable trigger user;

alter table public.depenses disable trigger user;
update public.depenses d
   set sortie_le = (d.created_at at time zone 'UTC')::date
 where d.statut = 'sortie' and d.sortie_le is not null and d.recu_serveur_le is null   -- dépenses d'avant la 0.9.17
   and (d.created_at at time zone 'UTC')::date > d.sortie_le
   and (d.created_at at time zone 'UTC')::date <= current_date
   and not exists (select 1 from public.clotures_caisse k
                   where k.organisation_id = d.organisation_id and k.site_id = d.site_id and k.encaisse_par = d.sortie_par
                     and k.jour in (d.sortie_le, (d.created_at at time zone 'UTC')::date));
alter table public.depenses enable trigger user;
