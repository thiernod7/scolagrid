-- Test de la migration 013 : journal des documents imprimés.
-- S : secrétaire du site 1 (inscrit). G : enseignant.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
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
insert into public.impressions_documents (organisation_id, eleve_id, inscription_id, type_document, rang, par)
  values (:'org_a', 'e0000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'attestation_inscription', 1, :'a');
do $$ begin
  assert (select par from public.impressions_documents) = '88888888-8888-8888-8888-888888888888', 'L''auteur est celui qui est connecté';
  -- Un duplicata sans motif : refusé
  begin
    insert into public.impressions_documents (organisation_id, eleve_id, inscription_id, type_document, rang)
      values ((select organisation_id from public.eleves limit 1), 'e0000000-0000-0000-0000-000000000002',
              '10000000-0000-0000-0000-000000000002', 'attestation_inscription', 2);
    raise exception 'Duplicata sans motif accepté';
  exception when check_violation then null;
  end;
  begin
    update public.impressions_documents set rang = 5;
    raise exception 'Le journal a été modifié';
  exception when insufficient_privilege then null;
  end;
end $$;
insert into public.impressions_documents (organisation_id, eleve_id, inscription_id, type_document, rang, motif)
  values (:'org_a', 'e0000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'attestation_inscription', 2, 'Original perdu');
commit;

-- G (enseignant) ne peut pas éditer de document officiel
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  begin
    insert into public.impressions_documents (organisation_id, eleve_id, type_document, rang)
      values ((select organisation_id from public.eleves limit 1), 'e0000000-0000-0000-0000-000000000002', 'attestation_inscription', 1);
    raise exception 'Un enseignant a édité une attestation';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

do $$ begin
  assert (select count(*) from public.impressions_documents) = 2, 'Original et duplicata notés';
end $$;

\echo 'Test 013 : tout est conforme.'
