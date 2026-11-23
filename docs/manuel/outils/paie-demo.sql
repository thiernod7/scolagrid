-- Paie de démonstration (ESSAI seulement) : grille des taux, rémunérations des
-- enseignants fictifs, un vacataire au collège payé à l'heure, une avance.
-- Rejouable : ne fait rien si c'est déjà fait. Pas de compte, pas de téléphone.
-- Variable psql : tel (numéro de test de l'école de démonstration).
\set ON_ERROR_STOP on
begin;
select o.id as org
  from auth.users u join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  where u.phone = :'tel' limit 1 \gset
select count(*) > 0 as deja from public.personnel where organisation_id = :'org' and nom_complet = 'Ibrahima SOW' \gset
\if :deja
  \echo 'Paie de démonstration déjà prête.'
  rollback;
  \quit
\endif
select a.debut as debut from public.annees_scolaires a where a.organisation_id = :'org' and a.en_cours \gset
-- La grille de l'école : le taux de l'heure par cycle.
insert into public.grille_taux (organisation_id, cycle, taux_gnf)
  select distinct :'org', n.cycle, case when n.cycle = 'lycee' then 35000 else 25000 end
    from public.niveaux n where n.organisation_id = :'org' and n.cycle not in ('maternelle', 'primaire')
  on conflict (organisation_id, cycle) do nothing;
-- Au mois : le maître de CP1 A, l'enseignante de calcul, la caissière.
insert into public.remunerations (organisation_id, personnel_id, mode, salaire_mensuel_gnf)
  select :'org', p.id, 'mensuel', x.salaire
    from public.personnel p join (values ('Mamadou DIALLO', 1800000), ('Fatoumata CAMARA', 1500000), ('Mariama KOUROUMA', 1200000)) x(nom, salaire)
      on x.nom = p.nom_complet
   where p.organisation_id = :'org'
  on conflict (personnel_id) do nothing;
-- Un vacataire au collège : maths (6 h) et physique (4 h) en 7ème A, à 25 000 GNF l'heure.
insert into public.personnel (organisation_id, nom_complet, prenoms, nom, contrat, date_embauche)
  values (:'org', 'Ibrahima SOW', 'Ibrahima', 'SOW', 'vacataire', :'debut') returning id as vacataire \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'vacataire', 'enseignant');
insert into public.remunerations (organisation_id, personnel_id, mode) values (:'org', :'vacataire', 'horaire');
insert into public.taux_horaires (organisation_id, personnel_id, cycle, taux_gnf)
  select :'org', :'vacataire', n.cycle, 25000 from public.classes c join public.niveaux n on n.id = c.niveau_id
   join public.annees_scolaires a on a.id = c.annee_id and a.en_cours
   where c.organisation_id = :'org' and c.nom = '7ème A' limit 1;
insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id, debut, heures_semaine)
  select :'org', :'vacataire', c.id, m.id, :'debut', x.heures
    from public.classes c join public.annees_scolaires a on a.id = c.annee_id and a.en_cours
    join public.matieres m on m.niveau_id = c.niveau_id
    join (values ('Mathématiques', 6.0), ('Physique-Chimie', 4.0), ('Biologie', 4.0)) x(matiere, heures) on x.matiere = m.nom
   where c.organisation_id = :'org' and c.nom = '7ème A';
-- Une avance à la caissière : 300 000 GNF par Orange Money, remboursée en 3 mois.
insert into public.avances (organisation_id, personnel_id, montant_gnf, mensualites, mode, reference, motif)
  select :'org', p.id, 300000, 3, 'orange_money', 'OM-DEMO-001', 'Frais médicaux'
    from public.personnel p where p.organisation_id = :'org' and p.nom_complet = 'Mariama KOUROUMA';
commit;
\echo 'Paie de démonstration prête.'
