-- 039 : pages masquées à une personne, à côté de ses droits.
--
-- Le fondateur peut décider qu'une personne ne voit pas, pour le moment, une
-- page de l'app (Dépenses, Familles…), quels que soient les droits de ses
-- fonctions. C'est une exception de plus sur sa fiche (droits_personnel),
-- « masquer_<page> » accordé = page cachée dans son menu. Ces valeurs ne
-- donnent ni ne retirent aucun droit : scolagrid.rattachement_a ne les lit pas.

alter table public.droits_personnel drop constraint droits_personnel_droit_check;
alter table public.droits_personnel add constraint droits_personnel_droit_check check (droit in (
  'valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps', 'planifier_evaluations',
  'saisir_notes', 'faire_appel', 'justifier_absence', 'preparer_paie', 'valider_paie',
  'verser_paie', 'consulter_tableau_bord', 'autoriser_depense',
  'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse', 'voir_personnel',
  'masquer_eleves', 'masquer_familles', 'masquer_notes', 'masquer_caisse',
  'masquer_depenses', 'masquer_recouvrement', 'masquer_personnel'));
