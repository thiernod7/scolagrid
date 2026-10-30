-- Test de la migration 002, joué par GitHub sur une base jetable.
-- A crée son espace école ; B (autre personne) ne doit rien voir ni modifier.
-- Chaque vérification lève une erreur si elle échoue, ce qui fait échouer le test.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'

insert into auth.users (id, aud, role, phone) values
  (:'a', 'authenticated', 'authenticated', '224620000001'),
  (:'b', 'authenticated', 'authenticated', '224620000002');

-- A crée son espace
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'a', 'role', 'authenticated', 'is_anonymous', false)::text, true);
set local role authenticated;
select public.creer_espace_ecole('Groupe scolaire Test', 'Conakry', 'Site de Kaloum', 'Fondateur Test') as org \gset
do $$ begin
  assert (select count(*) from public.organisations) = 1, 'A doit voir son organisation';
  assert (select count(*) from public.sites) = 1, 'A doit voir son site';
  assert (select role from public.rattachements) = 'fondateur', 'A doit être fondateur';
  assert (select telephone from public.personnes) = '224620000001', 'Le profil de A doit avoir son téléphone';
end $$;
-- A ajoute un site et renomme son organisation, mais ne peut pas s'activer lui-même
insert into public.sites (organisation_id, nom) values (:'org', 'Site de Ratoma');
update public.organisations set nom = 'Groupe scolaire Renommé', statut = 'active';
do $$ begin
  assert (select count(*) from public.sites) = 2, 'A doit pouvoir ajouter un site';
  assert (select nom from public.organisations) = 'Groupe scolaire Renommé', 'A doit pouvoir renommer';
  assert (select statut from public.organisations) = 'en_attente', 'A ne doit pas pouvoir changer le statut';
end $$;
commit;

-- B ne voit rien et ne peut rien faire chez A
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'b', 'role', 'authenticated', 'is_anonymous', false)::text, true);
select set_config('test.org', :'org', true);
set local role authenticated;
do $$ begin
  assert (select count(*) from public.organisations) = 0, 'B ne doit voir aucune organisation';
  assert (select count(*) from public.sites) = 0, 'B ne doit voir aucun site';
  assert (select count(*) from public.rattachements) = 0, 'B ne doit voir aucun rattachement';
  assert (select count(*) from public.personnes) = 0, 'B ne doit voir aucun profil';
  begin
    insert into public.sites (organisation_id, nom) values (current_setting('test.org')::uuid, 'Site intrus');
    raise exception 'B a pu ajouter un site chez A';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.rattachements (organisation_id, user_id, role)
    values (current_setting('test.org')::uuid, (current_setting('request.jwt.claims')::json ->> 'sub')::uuid, 'fondateur');
    raise exception 'B a pu se rattacher chez A';
  exception when insufficient_privilege then null;
  end;
end $$;
update public.organisations set nom = 'Piraté' where id = :'org';
commit;
do $$ begin
  assert (select nom from public.organisations) = 'Groupe scolaire Renommé', 'B ne doit pas pouvoir renommer chez A';
end $$;

-- Une session anonyme ne peut pas créer d'espace
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'b', 'role', 'authenticated', 'is_anonymous', true)::text, true);
set local role authenticated;
do $$ begin
  perform public.creer_espace_ecole('Groupe anonyme', 'Conakry', 'Site', 'Anonyme');
  raise exception 'Une session anonyme a pu créer un espace';
exception when insufficient_privilege then null;
end $$;
commit;

\echo 'Test 002 : tout est conforme.'
