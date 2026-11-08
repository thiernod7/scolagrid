-- École de démonstration (ESSAI seulement, données FICTIVES) : clôture les
-- journées de caisse passées restées ouvertes. Les captures encaissent chaque
-- jour ; sans clôture, l'app bloque l'encaissement suivant (clôture dans l'ordre).
-- Compté = espèces attendues (recalculées par le serveur ; sinon « à vérifier »).
-- Variable psql : tel (numéro de test de l'école de démonstration).
\set ON_ERROR_STOP on
begin;
select o.id as org
  from auth.users u join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  where u.phone = :'tel' limit 1 \gset
insert into public.clotures_caisse (organisation_id, site_id, encaisse_par, jour, compte_especes, ecart)
select e.organisation_id, e.site_id, e.encaisse_par, e.jour_caisse,
       greatest(0, coalesce(sum(e.total_gnf) filter (where e.mode = 'especes'), 0)
         - (select coalesce(sum(d.montant_gnf), 0) from public.depenses d
             where d.organisation_id = e.organisation_id and d.site_id = e.site_id and d.sortie_par = e.encaisse_par
               and d.sortie_le = e.jour_caisse and d.statut = 'sortie')
         - (select coalesce(sum(r.montant_gnf), 0) from public.remboursements r
             where r.organisation_id = e.organisation_id and r.site_id = e.site_id and r.verse_par = e.encaisse_par
               and r.verse_le = e.jour_caisse and r.statut = 'verse' and r.mode = 'especes')),
       0
from public.encaissements e
where e.organisation_id = :'org' and e.statut = 'valide' and e.jour_caisse < current_date
  and not exists (select 1 from public.clotures_caisse c where c.organisation_id = e.organisation_id
                  and c.site_id = e.site_id and c.encaisse_par = e.encaisse_par and c.jour = e.jour_caisse)
group by e.organisation_id, e.site_id, e.encaisse_par, e.jour_caisse
order by e.jour_caisse;
commit;
\echo 'Journées passées de la démonstration clôturées.'
