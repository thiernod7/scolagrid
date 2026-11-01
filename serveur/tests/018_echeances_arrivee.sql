-- Test de la migration 018 : délai de grâce, arrivée en cours d'année, échéancier aménagé.
-- S : secrétaire du site 1. D : directeur du site 1 (avec sa fiche). G : enseignant.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set d '44444444-4444-4444-4444-444444444444'
\set g '77777777-7777-7777-7777-777777777777'
\set s '88888888-8888-8888-8888-888888888888'
\set ins '10000000-0000-0000-0000-000000000001'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as frais from public.frais where organisation_id = :'org_a' limit 1 \gset
select set_config('test.ins', :'ins', false), set_config('test.frais', :'frais', false), set_config('test.org', :'org_a', false);

do $$ begin
  assert (select delai_grace_jours from public.organisations where id = current_setting('test.org')::uuid) = 7, 'Grâce de 7 jours par défaut';
  assert (select arrivee_par_defaut from public.organisations where id = current_setting('test.org')::uuid) = 'mois', 'Par défaut : à partir du mois d''arrivée';
end $$;

-- La secrétaire : « à partir du mois d'arrivée » oui, montant négocié non.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
update public.inscriptions set arrivee_mode = 'mois' where id = :'ins';
do $$ begin
  begin
    update public.inscriptions set arrivee_mode = 'negocie', arrivee_retrait_gnf = 50000, arrivee_motif = 'Accord du directeur'
      where id = current_setting('test.ins')::uuid;
    raise exception 'La secrétaire a accordé un montant négocié';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- Le directeur : montant négocié avec motif ; sans motif, refusé.
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  begin
    update public.inscriptions set arrivee_mode = 'negocie', arrivee_retrait_gnf = 50000 where id = current_setting('test.ins')::uuid;
    raise exception 'Montant négocié sans motif accepté';
  exception when check_violation then null;
  end;
end $$;
update public.inscriptions set arrivee_mode = 'negocie', arrivee_retrait_gnf = 50000, arrivee_motif = 'Accord avec le père' where id = :'ins';
-- Échéancier aménagé
insert into public.echeances_eleves (organisation_id, inscription_id, frais_id, ordre, libelle, montant_gnf, date_limite, motif)
  values (:'org_a', :'ins', :'frais', 1, 'Tranche 1a', 75000, '2026-10-30', 'Père payé en fin de mois'),
         (:'org_a', :'ins', :'frais', 2, 'Tranche 1b', 75000, '2026-11-30', 'Père payé en fin de mois');
commit;
do $$ begin
  assert (select arrivee_retrait_gnf from public.inscriptions where id = current_setting('test.ins')::uuid) = 50000, 'Montant négocié noté';
  assert (select count(*) from public.echeances_eleves) = 2, 'Échéancier aménagé enregistré';
  assert (select par from public.echeances_eleves limit 1) = '44444444-4444-4444-4444-444444444444', 'Auteur noté';
end $$;

-- Revenir à « année complète » efface la somme retirée.
update public.inscriptions set arrivee_mode = 'complete' where id = :'ins';
do $$ begin
  assert (select arrivee_retrait_gnf from public.inscriptions where id = current_setting('test.ins')::uuid) is null, 'Plus de somme retirée';
end $$;

-- L'enseignant ne voit ni ne change l'échéancier.
begin;
select pg_temp.connecte(:'g');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.echeances_eleves) = 0, 'L''enseignant ne voit pas l''échéancier';
end $$;
delete from public.echeances_eleves;
commit;
do $$ begin
  assert (select count(*) from public.echeances_eleves) = 2, 'L''enseignant ne supprime rien';
end $$;

-- La secrétaire voit l'échéancier mais ne l'aménage pas.
begin;
select pg_temp.connecte(:'s');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.echeances_eleves) = 2, 'La secrétaire voit l''échéancier';
  begin
    insert into public.echeances_eleves (organisation_id, inscription_id, frais_id, ordre, libelle, montant_gnf, date_limite, motif)
      values (current_setting('test.org')::uuid, current_setting('test.ins')::uuid, current_setting('test.frais')::uuid, 3, 'X', 1, '2026-12-01', 'essai');
    raise exception 'La secrétaire a aménagé un échéancier';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;
delete from public.echeances_eleves;
update public.inscriptions set arrivee_mode = null where id = :'ins';
\echo 'Test 018 : tout est conforme.'
