-- 017 : matières et coefficients, aussi par la direction des études.
--
-- Les matières et leurs coefficients relèvent de l'organisation des
-- évaluations : ceux qui ont le droit « planifier les évaluations »
-- (directeur, directeur des études, ou ce droit accordé à quelqu'un) les
-- gèrent, en plus du fondateur. Années et niveaux restent au fondateur.

drop policy "fondateur ajoute" on public.matieres;
drop policy "fondateur modifie" on public.matieres;
drop policy "fondateur supprime" on public.matieres;

create policy "études ajoutent" on public.matieres for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id)
              or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "études modifient" on public.matieres for update to authenticated
  using (scolagrid.est_fondateur(organisation_id)
         or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'))
  with check (scolagrid.est_fondateur(organisation_id)
              or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
create policy "études suppriment" on public.matieres for delete to authenticated
  using (scolagrid.est_fondateur(organisation_id)
         or scolagrid.a_le_droit_quelque_part(organisation_id, 'planifier_evaluations'));
