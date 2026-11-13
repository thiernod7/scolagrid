-- Test de la migration 043 : historique des notes, correction motivée, remise, décisions de fin d'année.
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
select i.id as ins, i.eleve_id as eleve from public.inscriptions i where i.organisation_id = :'org' limit 1 \gset
insert into public.types_evaluation (organisation_id, libelle, poids) values (:'org', 'Évaluation', 1)
  on conflict (organisation_id, libelle) do nothing;
select id as t_eval from public.types_evaluation where organisation_id = :'org' and libelle = 'Évaluation' \gset
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', 'test-043', 1, '1er trimestre', '2026-10-01', '2026-12-19', 10) returning id as periode \gset
insert into public.sessions_evaluation (organisation_id, periode_id, type_id, libelle, debut, fin)
  values (:'org', :'periode', :'t_eval', 'Évaluation d''octobre', '2026-10-01', '2026-10-31') returning id as sess \gset
insert into public.evaluations (organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation)
  values (:'org', :'periode', :'sess', :'classe', :'matiere', :'t_eval', '2026-10-20') returning id as ev \gset
select set_config('test.ev', :'ev', false), set_config('test.sess', :'sess', false), set_config('test.org', :'org', false),
       set_config('test.ins', :'ins', false);

select pg_temp.connecte(:'g');
set local role authenticated;
insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat) values (:'org', :'ev', :'eleve', 6, 'note');
update public.notes set valeur = 7 where evaluation_id = :'ev';
-- L'enseignant remet ses notes.
update public.evaluations set remise_le = now() where id = :'ev';
do $$ begin
  assert (select count(*) from public.notes_historique where evaluation_id = current_setting('test.ev')::uuid) = 1, 'Modification tracée';
  assert (select avant_valeur = 6 and apres_valeur = 7 from public.notes_historique where evaluation_id = current_setting('test.ev')::uuid),
    'Ancienne et nouvelle valeur';
  assert (select remise_par is not null from public.evaluations where id = current_setting('test.ev')::uuid), 'Remise notée';
  -- L'historique ne s'écrit pas à la main.
  begin
    insert into public.notes_historique (organisation_id, note_id, evaluation_id, eleve_id)
      values (current_setting('test.org')::uuid, gen_random_uuid(), current_setting('test.ev')::uuid, gen_random_uuid());
    assert false, 'Historique écrit à la main';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- Session clôturée : correction refusée sans motif, acceptée avec, et tracée avec son motif.
update public.sessions_evaluation set statut = 'cloturee' where id = :'sess';
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  update public.notes set valeur = 8, motif = null where evaluation_id = current_setting('test.ev')::uuid;
  assert false, 'Correction sans motif acceptée';
exception when check_violation then null;
end $$;
update public.notes set valeur = 8, motif = 'Erreur de report de la copie' where evaluation_id = :'ev';
do $$ begin
  assert (select motif from public.notes_historique where evaluation_id = current_setting('test.ev')::uuid and apres_valeur = 8)
    = 'Erreur de report de la copie', 'Motif dans l''historique';
end $$;
reset role;

-- Fin d'année : « admis par décision du conseil » exige un motif.
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  insert into public.decisions_annee (organisation_id, annee_id, inscription_id, eleve_id, moyenne_annuelle, proposition, decision)
    values (current_setting('test.org')::uuid, gen_random_uuid(), current_setting('test.ins')::uuid, gen_random_uuid(), 9.75, 'redouble', 'admis_conseil');
  assert false, 'Admis par le conseil sans motif';
exception when check_violation then null;
end $$;
insert into public.decisions_annee (organisation_id, annee_id, inscription_id, eleve_id, moyenne_annuelle, proposition, decision, motif)
  values (:'org', :'annee', :'ins', :'eleve', 9.75, 'redouble', 'admis_conseil', 'Progression constante au 2e semestre');
do $$ begin
  assert (select par is not null and eleve_id is not null from public.decisions_annee where inscription_id = current_setting('test.ins')::uuid),
    'Décision tracée';
end $$;
reset role;
-- Un enseignant ne décide pas.
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  update public.decisions_annee set decision = 'exclu' where inscription_id = current_setting('test.ins')::uuid;
  assert (select decision from public.decisions_annee where inscription_id = current_setting('test.ins')::uuid) = 'admis_conseil',
    'Décision changée par un enseignant';
end $$;
reset role;
rollback;
\echo '043 contrôle et fin d''année : OK'
