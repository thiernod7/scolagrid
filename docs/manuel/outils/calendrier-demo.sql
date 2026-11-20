-- Calendrier de démonstration (ESSAI seulement) : la prochaine composition de
-- l'école de démonstration passe « en préparation » (à programmer 5 jours avant),
-- avec deux matières de la CE2 A déjà programmées (heure et durée). Les autres
-- restent « à programmer ». Rejouable : ne fait rien si c'est déjà fait.
-- Variable psql : tel (numéro de test de l'école de démonstration).
\set ON_ERROR_STOP on
begin;
select o.id as org
  from auth.users u join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  where u.phone = :'tel' limit 1 \gset
select count(*) > 0 as trouve
  from public.sessions_evaluation s join public.types_evaluation t on t.id = s.type_id
  join public.periodes_evaluation p on p.id = s.periode_id
  where s.organisation_id = :'org' and t.unique_par_periode and s.statut = 'ouverte' and s.fin >= current_date and p.cycle = 'primaire' \gset
\if :trouve
\else
  \echo 'Pas de composition à venir dans la démonstration.'
  rollback;
  \quit
\endif
select s.id as sess, s.debut as debut, s.periode_id as periode, s.type_id as type_id, s.calendrier as cal
  from public.sessions_evaluation s join public.types_evaluation t on t.id = s.type_id
  join public.periodes_evaluation p on p.id = s.periode_id
  where s.organisation_id = :'org' and t.unique_par_periode and s.statut = 'ouverte' and s.fin >= current_date and p.cycle = 'primaire'
  order by s.debut limit 1 \gset
select :'cal' <> 'libre' as deja \gset
\if :deja
  \echo 'Calendrier de démonstration déjà prêt.'
  rollback;
  \quit
\endif
update public.sessions_evaluation set calendrier = 'preparation', programmation_avant = (:'debut'::date - 5) where id = :'sess';
insert into public.evaluations (organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation, heure, duree_min)
  select :'org', :'periode', :'sess', c.id, m.id, :'type_id', (:'debut'::date + x.jour), x.heure, x.duree
    from public.classes c join public.annees_scolaires a on a.id = c.annee_id and a.en_cours
    join public.matieres m on m.niveau_id = c.niveau_id
    join (values ('Calcul', 1, '08:00', 120), ('Français', 1, '10:30', 90)) as x(matiere, jour, heure, duree) on x.matiere = m.nom
   where c.organisation_id = :'org' and c.nom = 'CE2 A'
     and not exists (select 1 from public.evaluations e where e.session_id = :'sess' and e.classe_id = c.id and e.matiere_id = m.id);
commit;
\echo 'Calendrier de démonstration prêt.'
