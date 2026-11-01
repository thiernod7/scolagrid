-- Test de la migration 021 : pièces réglables, blocage des documents, seuil.
-- A : fondateur. S : secrétaire.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select set_config('test.org', :'org_a', false);

do $$ begin
  assert (select blocage_documents from public.organisations where id = current_setting('test.org')::uuid) = 'alerte', 'Alerte par défaut';
  assert (select seuil_recouvrement from public.organisations where id = current_setting('test.org')::uuid) = 70, 'Seuil de 70 %';
end $$;

begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.pieces_dossier (organisation_id, code, libelle, admissions, cycles, obligatoire, ordre) values
  (:'org_a', 'acte_naissance', 'Extrait de naissance', 'nouvelle,transfert', null, true, 1),
  (:'org_a', 'vaccination', 'Carnet de vaccination', null, 'maternelle,primaire', false, 2),
  (:'org_a', 'fiche_transfert', 'Fiche de transfert', 'transfert', null, true, 3);
update public.organisations set blocage_documents = 'bloquer', seuil_recouvrement = 80 where id = :'org_a';
commit;
do $$ begin
  assert (select count(*) from public.pieces_dossier) = 3, 'Trois pièces';
  begin
    insert into public.pieces_dossier (organisation_id, code, libelle, cycles)
      values (current_setting('test.org')::uuid, 'x_y', 'Pièce', 'universite');
    raise exception 'Cycle inconnu accepté';
  exception when check_violation then null;
  end;
end $$;

-- La secrétaire voit la liste mais ne la change pas.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.pieces_dossier) = 3, 'La secrétaire voit les pièces';
  begin
    insert into public.pieces_dossier (organisation_id, code, libelle)
      values (current_setting('test.org')::uuid, 'autre', 'Autre pièce');
    raise exception 'La secrétaire a ajouté une pièce';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
update public.organisations set blocage_documents = 'alerte', seuil_recouvrement = 70 where id = :'org_a';
delete from public.pieces_dossier;
\echo 'Test 021 : tout est conforme.'
