-- Test de la migration 045 : calendrier préparé, publié puis figé ; pas de note avant le jour de l'épreuve.
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
select c.id as classe, c.niveau_id as niveau from public.classes c
  where c.organisation_id = :'org' and exists (select 1 from public.inscriptions i where i.classe_id = c.id) order by c.created_at limit 1 \gset
select id as matiere from public.matieres where niveau_id = :'niveau' order by nom limit 1 \gset
select i.eleve_id as eleve from public.inscriptions i where i.classe_id = :'classe' limit 1 \gset
insert into public.enseignements (organisation_id, personnel_id, classe_id, matiere_id, debut)
  select :'org', id, :'classe', :'matiere', current_date - 60 from public.personnel where user_id = :'g' and organisation_id = :'org';
insert into public.types_evaluation (organisation_id, libelle, poids, unique_par_periode) values (:'org', 'Composition', 2, true)
  on conflict (organisation_id, libelle) do nothing;
select id as t_compo from public.types_evaluation where organisation_id = :'org' and libelle = 'Composition' \gset
insert into public.periodes_evaluation (organisation_id, annee_id, cycle, ordre, libelle, debut, fin, bareme)
  values (:'org', :'annee', 'test-045', 1, 'Période', current_date - 30, current_date + 60, 20) returning id as periode \gset
-- La composition à venir : en préparation, à programmer avant demain.
insert into public.sessions_evaluation (organisation_id, periode_id, type_id, libelle, debut, fin, calendrier, programmation_avant)
  values (:'org', :'periode', :'t_compo', 'Composition', current_date - 2, current_date + 20, 'preparation', current_date + 1)
  returning id as sess \gset
select set_config('test.org', :'org', false), set_config('test.sess', :'sess', false), set_config('test.classe', :'classe', false),
       set_config('test.matiere', :'matiere', false), set_config('test.periode', :'periode', false),
       set_config('test.t_compo', :'t_compo', false), set_config('test.eleve', :'eleve', false);

-- En préparation : l'enseignant programme sa composition (dans 5 jours, à 8 h, 2 heures).
select pg_temp.connecte(:'g');
set local role authenticated;
insert into public.evaluations (organisation_id, periode_id, session_id, classe_id, matiere_id, type_id, date_evaluation, heure, duree_min)
  values (:'org', :'periode', :'sess', :'classe', :'matiere', :'t_compo', current_date + 5, '08:00', 120) returning id as ev \gset
select set_config('test.ev', :'ev', false);
do $$ begin
  -- Pas de note avant le jour de l'épreuve.
  begin
    insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat)
      values (current_setting('test.org')::uuid, current_setting('test.ev')::uuid, current_setting('test.eleve')::uuid, 12, 'note');
    assert false, 'Note saisie avant le jour de l''épreuve';
  exception when check_violation then null;
  end;
  -- Il peut encore la déplacer.
  update public.evaluations set date_evaluation = current_date + 6 where id = current_setting('test.ev')::uuid;
  assert (select date_evaluation = current_date + 6 from public.evaluations where id = current_setting('test.ev')::uuid), 'Déplacée en préparation';
end $$;
reset role;

-- La direction publie : la date prévue est fixée.
select pg_temp.connecte(:'d');
set local role authenticated;
update public.sessions_evaluation set calendrier = 'publie' where id = :'sess';
do $$ begin
  assert (select publie_le is not null and publie_par is not null from public.sessions_evaluation where id = current_setting('test.sess')::uuid),
    'Publication datée';
  assert (select date_prevue = current_date + 6 from public.evaluations where id = current_setting('test.ev')::uuid), 'Date prévue fixée';
end $$;
reset role;

-- Publiée : l'enseignant ne déplace plus, n'ajoute plus, ne retire plus.
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  begin
    update public.evaluations set date_evaluation = current_date + 7 where id = current_setting('test.ev')::uuid;
    assert false, 'Épreuve déplacée par l''enseignant après publication';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.evaluations where id = current_setting('test.ev')::uuid;
    assert false, 'Épreuve retirée par l''enseignant après publication';
  exception when insufficient_privilege then null;
  end;
  -- La remise des notes reste possible.
  update public.evaluations set remise_le = now() where id = current_setting('test.ev')::uuid;
end $$;
reset role;

-- La direction la déplace (coupure, jour férié) : la date prévue reste celle du calendrier.
select pg_temp.connecte(:'d');
set local role authenticated;
update public.evaluations set date_evaluation = current_date - 1 where id = :'ev';
do $$ begin
  assert (select date_prevue = current_date + 6 and date_evaluation = current_date - 1 from public.evaluations
          where id = current_setting('test.ev')::uuid), 'Date prévue gardée, date réelle changée';
end $$;
reset role;

-- Le jour passé, l'enseignant saisit.
select pg_temp.connecte(:'g');
set local role authenticated;
insert into public.notes (organisation_id, evaluation_id, eleve_id, valeur, etat) values (:'org', :'ev', :'eleve', 14, 'note');
reset role;
select pg_temp.connecte(:'d');
do $$ begin
  assert (select count(*) from public.notes where evaluation_id = current_setting('test.ev')::uuid) = 1, 'Note saisie après l''épreuve';
  -- Heure mal écrite : refusée.
  begin
    update public.evaluations set heure = '25:00' where id = current_setting('test.ev')::uuid;
    assert false, 'Heure impossible acceptée';
  exception when check_violation then null;
  end;
end $$;
rollback;
\echo '045 calendrier : OK'
