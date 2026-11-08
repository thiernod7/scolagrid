-- Matières, périodes, évaluations et notes FICTIVES pour l'école de démonstration
-- (ESSAI seulement), pour vérifier l'écran Notes. Rejouable : ne refait rien si des
-- évaluations existent déjà. Variable psql : tel (numéro de test de l'école).
\set ON_ERROR_STOP on
begin;
select o.id as org, u.id as moi from auth.users u
  join public.organisations o on o.cree_par = u.id and o.nom = 'Groupe scolaire Les Manguiers'
  where u.phone = :'tel' limit 1 \gset
select id as annee, debut, fin from public.annees_scolaires where organisation_id = :'org' and en_cours limit 1 \gset
select count(*) > 0 as deja from public.evaluations where organisation_id = :'org' \gset
\if :deja
  \echo 'Notes de démonstration déjà présentes.'
  rollback;
  \quit
\endif
select set_config('demo.org', :'org', true), set_config('demo.annee', :'annee', true), set_config('demo.moi', :'moi', true);
do $$
declare
  org uuid := current_setting('demo.org')::uuid; an uuid := current_setting('demo.annee')::uuid;
  n record; c record; e record; m record; p uuid; t_eval uuid; t_compo uuid; ev uuid; i int := 0; d date; f date;
begin
  select debut, fin into d, f from public.annees_scolaires where id = an;
  -- Matières par niveau (si aucune).
  for n in select * from public.niveaux where organisation_id = org loop
    if not exists (select 1 from public.matieres where niveau_id = n.id) then
      if n.cycle = 'primaire' then
        insert into public.matieres (organisation_id, niveau_id, nom, coefficient) values
          (org, n.id, 'Calcul', 3), (org, n.id, 'Français', 3), (org, n.id, 'Sciences d''observation', 2), (org, n.id, 'Histoire-Géographie', 1);
      else
        insert into public.matieres (organisation_id, niveau_id, nom, coefficient) values
          (org, n.id, 'Mathématiques', 4), (org, n.id, 'Français', 3), (org, n.id, 'Anglais', 2), (org, n.id, 'Biologie', 2);
      end if;
    end if;
  end loop;
  -- Types d'évaluation.
  if not exists (select 1 from public.types_evaluation where organisation_id = org) then
    insert into public.types_evaluation (organisation_id, libelle, poids, compte, unique_par_periode, ordre) values
      (org, 'Évaluation', 1, true, false, 1), (org, 'Composition', 2, true, true, 2), (org, 'Examen blanc', 1, false, false, 3);
  end if;
  select id into t_eval from public.types_evaluation where organisation_id = org and libelle = 'Évaluation';
  select id into t_compo from public.types_evaluation where organisation_id = org and libelle = 'Composition';
  -- Périodes : primaire 3 trimestres sur 10, collège 2 semestres sur 20.
  if not exists (select 1 from public.periodes_evaluation where annee_id = an and cycle = 'primaire') then
    insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme) values
      (org, an, 'primaire', 1, '1er trimestre', d, d + 90, 10), (org, an, 'primaire', 2, '2e trimestre', d + 91, d + 181, 10),
      (org, an, 'primaire', 3, '3e trimestre', d + 182, f, 10);
  end if;
  if not exists (select 1 from public.periodes_evaluation where annee_id = an and cycle = 'college') then
    insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme) values
      (org, an, 'college', 1, '1er semestre', d, d + 135, 20), (org, an, 'college', 2, '2e semestre', d + 136, f, 20);
  end if;
  -- Deux évaluations par matière en CE2 A et 7ème A, notes pseudo-aléatoires stables.
  for c in select cl.id, cl.niveau_id, nv.cycle from public.classes cl join public.niveaux nv on nv.id = cl.niveau_id
           where cl.annee_id = an and cl.nom in ('CE2 A', '7ème A') loop
    select id into p from public.periodes_evaluation where annee_id = an and cycle = c.cycle and ordre = 1;
    for m in select * from public.matieres where niveau_id = c.niveau_id loop
      insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation, libelle)
        values (org, p, c.id, m.id, t_eval, d + 25, 'Évaluation d''octobre') returning id into ev;
      for e in select el.id from public.inscriptions ins join public.eleves el on el.id = ins.eleve_id where ins.classe_id = c.id loop
        i := i + 1;
        insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat)
          values (org, ev, e.id, case when c.cycle = 'primaire' then 4 + (i * 7 % 6) else 8 + (i * 7 % 11) end, 'note');
      end loop;
      insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation, libelle)
        values (org, p, c.id, m.id, t_eval, d + 40, 'Évaluation de novembre') returning id into ev;
      for e in select el.id from public.inscriptions ins join public.eleves el on el.id = ins.eleve_id where ins.classe_id = c.id loop
        i := i + 1;
        insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat)
          values (org, ev, e.id, case when c.cycle = 'primaire' then 3 + (i * 5 % 7) else 7 + (i * 5 % 13) end,
                  case when i % 17 = 0 then 'absent_justifie' else 'note' end);
      end loop;
    end loop;
  end loop;
end $$;
commit;
\echo 'Notes de démonstration créées.'
