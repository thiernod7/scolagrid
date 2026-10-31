-- Test de la migration 005, joué après les tests 002 à 004.
-- A : fondateur (sites 1 et 2). D : directeur du site 1. B : autre école.
-- G : enseignant du site 2 seulement.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as org_b from public.organisations where cree_par = :'b' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as site_2 from public.sites where organisation_id = :'org_a' and nom = 'Site de Ratoma' \gset
select set_config('test.org', :'org_a', false), set_config('test.site_1', :'site_1', false),
       set_config('test.site_2', :'site_2', false);

-- Les codes suivent l'alphabet, puis AA, AB…
do $$ begin
  assert scolagrid.code_poste(1) = 'A' and scolagrid.code_poste(26) = 'Z', 'Codes A à Z';
  assert scolagrid.code_poste(27) = 'AA' and scolagrid.code_poste(28) = 'AB' and scolagrid.code_poste(53) = 'BA', 'Codes à deux lettres';
end $$;

-- G : enseignant du site 2, ajouté par le fondateur (accès donné directement pour le test)
insert into auth.users (id, aud, role) values (:'g', 'authenticated', 'authenticated');
insert into public.personnel (organisation_id, site_id, nom_complet, user_id) values (:'org_a', :'site_2', 'Ibrahima Sow', :'g')
  returning id as fiche_g \gset
insert into public.affectations (organisation_id, personnel_id, site_id, fonction) values (:'org_a', :'fiche_g', :'site_2', 'enseignant');

-- A active deux postes : codes A et B. B active le sien : code A dans son école.
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
do $$ begin
  assert public.activer_poste(current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, 'PC du secrétariat', 'windows') ->> 'code' = 'A', 'Premier poste : A';
  assert public.activer_poste(current_setting('test.org')::uuid, null, 'Téléphone du fondateur', 'android') ->> 'code' = 'B', 'Deuxième poste : B';
end $$;
commit;
begin;
select pg_temp.connecte(:'b');
set local role authenticated;
do $$ begin
  assert public.activer_poste((select id from public.organisations limit 1), null, 'PC de B') ->> 'code' = 'A', 'Les codes sont propres à chaque école';
  assert (select count(*) from public.postes) = 1, 'B ne voit que son poste';
  begin
    perform public.activer_poste(current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, 'Intrus');
    raise exception 'B a activé un poste chez A';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- G : poste sur son site, pas sur le site 1 ni pour tout le groupe ; ne peut pas se débloquer
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$
declare p uuid;
begin
  p := (public.activer_poste(current_setting('test.org')::uuid, current_setting('test.site_2')::uuid, 'Téléphone de G', 'android') ->> 'id')::uuid;
  perform set_config('test.poste_g', p::text, false);
  begin
    perform public.activer_poste(current_setting('test.org')::uuid, current_setting('test.site_1')::uuid, 'Mauvais site');
    raise exception 'G a activé un poste sur un site où il ne travaille pas';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.activer_poste(current_setting('test.org')::uuid, null, 'Poste du groupe');
    raise exception 'G a activé un poste du groupe';
  exception when insufficient_privilege then null;
  end;
  assert (select count(*) from public.postes) = 1, 'G ne voit que son poste';
  -- Le poste signale sa synchro, mais ne peut changer ni son nom, ni son statut, ni son code
  update public.postes set derniere_synchro = '2030-01-01', nom = 'Renommé', code = 'Z', statut = 'bloque' where id = p;
end $$;
commit;
do $$ begin
  assert (select derniere_synchro = '2030-01-01' and nom = 'Téléphone de G' and code = 'C' and statut = 'actif'
          from public.postes where id = current_setting('test.poste_g')::uuid), 'G ne doit modifier que sa synchro';
end $$;

-- D, directeur du site 1 : voit le poste du site 1, pas celui du site 2 ; le bloque
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.postes) = 1, 'D ne doit voir que le poste du site 1';
end $$;
update public.postes set statut = 'bloque', derniere_synchro = '2000-01-01';
update public.postes set statut = 'bloque' where id = current_setting('test.poste_g')::uuid;   -- site 2 : ignoré
commit;
do $$ begin
  assert (select statut from public.postes where nom = 'PC du secrétariat') = 'bloque', 'D doit pouvoir bloquer un poste de son site';
  assert (select derniere_synchro <> '2000-01-01' from public.postes where nom = 'PC du secrétariat'), 'D ne doit pas changer la synchro du poste';
  assert (select statut from public.postes where id = current_setting('test.poste_g')::uuid) = 'actif', 'D ne doit pas bloquer un poste du site 2';
end $$;

-- A voit tous les postes de son école
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.postes) = 3, 'A doit voir les 3 postes de son école';
end $$;
commit;

\echo 'Test 005 : tout est conforme.'
