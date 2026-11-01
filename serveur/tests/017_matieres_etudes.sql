-- Test de la migration 017 : matières gérées par la direction des études.
-- D : directeur du site 1 (droit « planifier les évaluations » par défaut).
-- G : enseignant (pas ce droit).

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as niveau from public.niveaux where organisation_id = :'org_a' limit 1 \gset

begin;
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.matieres (organisation_id, niveau_id, nom, coefficient) values (:'org_a', :'niveau', 'Dessin', 1);
update public.matieres set coefficient = 2 where nom = 'Dessin';
commit;
do $$ begin
  assert (select coefficient from public.matieres where nom = 'Dessin') = 2, 'Le directeur gère les matières';
end $$;

begin;
select pg_temp.connecte(:'g');
set local role authenticated;
update public.matieres set coefficient = 5 where nom = 'Dessin';
do $$ begin
  begin
    insert into public.matieres (organisation_id, niveau_id, nom)
      values ((select organisation_id from public.niveaux limit 1), (select id from public.niveaux limit 1), 'Musique');
    raise exception 'Un enseignant a ajouté une matière';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
do $$ begin
  assert (select coefficient from public.matieres where nom = 'Dessin') = 2, 'L''enseignant ne change pas les coefficients';
end $$;
delete from public.matieres where nom = 'Dessin';
\echo 'Test 017 : tout est conforme.'
