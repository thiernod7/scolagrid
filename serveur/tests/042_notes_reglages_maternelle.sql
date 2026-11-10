-- Test de la migration 042 : maternelle par acquis, règles et mentions de l'école.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
select id as annee from public.annees_scolaires where organisation_id = :'org' and en_cours \gset
select c.id as classe, c.niveau_id as niveau from public.classes c where c.organisation_id = :'org' order by c.created_at limit 1 \gset
select id as matiere from public.matieres where niveau_id = :'niveau' limit 1 \gset
select e.id as eleve from public.eleves e where e.organisation_id = :'org' limit 1 \gset
insert into public.types_evaluation (organisation_id, libelle, poids) values (:'org', 'Évaluation', 1)
  on conflict (organisation_id, libelle) do nothing;
select id as t_eval from public.types_evaluation where organisation_id = :'org' and libelle = 'Évaluation' \gset
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme, nature)
  values (:'org', :'annee', 'test-042', 1, 'Année', '2026-10-01', '2027-06-30', 20, 'appreciations') returning id as periode \gset
insert into public.evaluations (organisation_id, periode_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'classe', :'matiere', :'t_eval', '2026-11-10') returning id as ev \gset
select set_config('test.org', :'org', false), set_config('test.ev', :'ev', false), set_config('test.eleve', :'eleve', false),
       set_config('test.periode', :'periode', false);

select pg_temp.connecte(:'g');
set local role authenticated;
-- Maternelle : un acquis, pas de chiffre (le chiffre envoyé est ignoré).
insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat, acquis) values (:'org', :'ev', :'eleve', 15, 'note', 'en_cours');
do $$ begin
  assert (select valeur is null and acquis = 'en_cours' from public.notes where evaluation_id = current_setting('test.ev')::uuid),
    'Acquis gardé, chiffre ignoré';
  begin
    update public.notes set acquis = null where evaluation_id = current_setting('test.ev')::uuid;
    assert false, 'Note de maternelle sans acquis acceptée';
  exception when check_violation then null;
  end;
end $$;
reset role;

-- La nature ne change plus une fois des notes saisies.
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  update public.periodes_evaluation set nature = 'numerique' where id = current_setting('test.periode')::uuid;
  assert false, 'Nature changée malgré les notes';
exception when check_violation then null;
end $$;
-- Règles et mentions : la direction (planifier_evaluations).
insert into public.regles_notes (organisation_id, absences) values (:'org', 'toujours_zero');
insert into public.mentions_notes (organisation_id, cycle, minimum, libelle) values (:'org', 'primaire', 8.5, 'Excellent');
reset role;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select absences from public.regles_notes where organisation_id = current_setting('test.org')::uuid) = 'toujours_zero', 'Règles lues';
  begin
    update public.regles_notes set absences = 'toujours_exclu' where organisation_id = current_setting('test.org')::uuid;
    assert (select absences from public.regles_notes where organisation_id = current_setting('test.org')::uuid) = 'toujours_zero',
      'Un enseignant ne change pas les règles';
  end;
end $$;
reset role;
rollback;
\echo '042 maternelle et règles : OK'
