-- Test de la migration 020 : l'école sur ses documents.
-- A : fondateur. S : secrétaire (imprime). G : enseignant.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select set_config('test.org', :'org_a', false);

begin;
select pg_temp.connecte(:'a');
set local role authenticated;
update public.organisations set numero_autorisation = 'MEPU-A 2011/0042', nif = '112345678', commune = 'Dixinn',
  telephone2 = '+224 664 12 34 56', mention_recu = 'Les frais versés ne sont pas remboursables.', signature_documents = true
  where id = :'org_a';
insert into public.images_ecole (organisation_id, sorte, type_image, image) values
  (:'org_a', 'logo', 'image/png', repeat('L', 500)),
  (:'org_a', 'signature', 'image/png', repeat('S', 500)),
  (:'org_a', 'cachet', 'image/png', repeat('C', 500));
commit;
do $$ begin
  assert (select numero_autorisation from public.organisations where id = current_setting('test.org')::uuid) = 'MEPU-A 2011/0042', 'Autorisation notée';
  assert (select count(*) from public.images_ecole) = 3, 'Logo, signature et cachet';
  begin
    update public.organisations set responsable_email = 'pas-un-email' where id = current_setting('test.org')::uuid;
    raise exception 'E-mail invalide accepté';
  exception when check_violation then null;
  end;
end $$;

-- La secrétaire voit les trois, mais ne change rien.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.images_ecole) = 3, 'La secrétaire voit signature et cachet';
end $$;
update public.images_ecole set image = repeat('X', 500);
commit;
do $$ begin
  assert (select count(*) from public.images_ecole where image like 'X%') = 0, 'La secrétaire ne change pas les images';
end $$;

-- L'enseignant ne voit que le logo.
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.images_ecole) = 1, 'L''enseignant ne voit que le logo';
  assert (select sorte from public.images_ecole) = 'logo', 'Le logo';
end $$;
commit;
delete from public.images_ecole;
\echo 'Test 020 : tout est conforme.'
