-- Test de la migration 015 : photos des élèves.
-- S : secrétaire (inscrit). G : enseignant (voit, ne change pas). B : autre école.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset

begin;
select pg_temp.connecte(:'s');
set local role authenticated;
insert into public.photos_eleves (organisation_id, eleve_id, type_image, image)
  values (:'org_a', 'e0000000-0000-0000-0000-000000000002', 'image/jpeg', repeat('A', 2000));
do $$ begin
  assert (select par from public.photos_eleves) = '88888888-8888-8888-8888-888888888888', 'Auteur noté';
  begin
    insert into public.photos_eleves (organisation_id, eleve_id, type_image, image)
      values ((select organisation_id from public.eleves limit 1), 'e0000000-0000-0000-0000-000000000003', 'image/jpeg', repeat('A', 500000));
    raise exception 'Photo trop lourde acceptée';
  exception when check_violation then null;
  end;
end $$;
-- Changer la photo : même élève
update public.photos_eleves set image = repeat('B', 3000), eleve_id = 'e0000000-0000-0000-0000-000000000003';
commit;
do $$ begin
  assert (select eleve_id from public.photos_eleves) = 'e0000000-0000-0000-0000-000000000002', 'La photo reste à son élève';
end $$;

begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.photos_eleves) = 1, 'L''enseignant voit les photos';
end $$;
update public.photos_eleves set image = repeat('C', 3000);
commit;
do $$ begin
  assert (select left(image, 1) from public.photos_eleves) = 'B', 'L''enseignant ne change pas la photo';
end $$;

begin;
select pg_temp.connecte(:'b');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.photos_eleves) = 0, 'B ne voit pas les photos de A';
end $$;
commit;

\echo 'Test 015 : tout est conforme.'
