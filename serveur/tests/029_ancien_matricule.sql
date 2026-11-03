-- Test de la migration 029 : ancien matricule facultatif, 40 caractères au plus.
\set ON_ERROR_STOP on
\set ins '10000000-0000-0000-0000-000000000001'
begin;
select eleve_id as eleve from public.inscriptions where id = :'ins' \gset
select set_config('test.eleve', :'eleve', false);
update public.eleves set ancien_matricule = '2023-145' where id = :'eleve';
do $$ begin
  assert (select ancien_matricule from public.eleves where id = current_setting('test.eleve')::uuid) = '2023-145', 'Ancien matricule gardé';
  begin
    update public.eleves set ancien_matricule = repeat('x', 41) where id = current_setting('test.eleve')::uuid;
    raise exception 'ÉCHEC : ancien matricule trop long accepté';
  exception when check_violation then null;
  end;
end $$;
select 'Test 029 : tout est conforme.';
rollback;
