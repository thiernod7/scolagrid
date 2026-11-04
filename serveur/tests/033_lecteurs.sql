-- Test de la migration 033 : un lecteur ne lit que ce qu'on lui accorde, et n'écrit rien.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set l '33333333-0000-0000-0000-000000000033'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
insert into auth.users (id, aud, role, phone) values (:'l', 'authenticated', 'authenticated', '224620000033');
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
insert into public.personnel (organisation_id, nom_complet, telephone) values (:'org', 'Lecteur Test', '224620000033') returning id as fiche \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'fiche', 'lecteur');
update public.personnel set user_id = :'l' where id = :'fiche';
select set_config('test.org', :'org', false), set_config('test.l', :'l', false), set_config('test.fiche', :'fiche', false);

do $$ declare r public.rattachements; begin
  select * into r from public.rattachements where user_id = current_setting('test.l')::uuid and role = 'lecteur' and actif;
  assert found, 'Rattachement lecteur créé';
  assert not r.lit_familles and not r.lit_caisse and not r.lit_personnel, 'Un lecteur ne lit rien par défaut';
end $$;

-- La direction lui accorde la caisse et le personnel.
insert into public.droits_personnel (organisation_id, personnel_id, droit, accorde) values
  (:'org', :'fiche', 'voir_caisse', true), (:'org', :'fiche', 'voir_personnel', true);
do $$ declare r public.rattachements; begin
  select * into r from public.rattachements where user_id = current_setting('test.l')::uuid and role = 'lecteur';
  assert r.lit_caisse and r.lit_personnel and not r.lit_familles, 'Lectures accordées';
end $$;
delete from public.droits_personnel where personnel_id = :'fiche' and droit = 'voir_personnel';
do $$ begin
  assert not (select lit_personnel from public.rattachements where user_id = current_setting('test.l')::uuid and role = 'lecteur'),
    'Lecture retirée';
  -- Les fonctions existantes gardent ce qu'elles voyaient.
  assert (select bool_and(lit_familles and lit_caisse and lit_personnel) from public.rattachements
          where organisation_id = current_setting('test.org')::uuid and role = 'fondateur'), 'Le fondateur lit tout';
end $$;

-- Il n'écrit rien : ni élève, ni contact.
select pg_temp.connecte(:'l');
set local role authenticated;
do $$ begin
  begin
    insert into public.contacts (organisation_id, nom_complet) values (current_setting('test.org')::uuid, 'Parent Test');
    raise exception 'ÉCHEC : un lecteur a créé un contact';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'Test 033 : tout est conforme.';
rollback;
