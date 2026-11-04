-- Test de la migration 031 : invitation par SMS (sans envoi réel : seuls les refus sont testés).
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
begin;
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
insert into public.personnel (organisation_id, nom_complet, prenoms, nom, telephone)
  values (:'org', 'Fanta SYLLA', 'Fanta', 'SYLLA', '224620000777') returning id as fiche \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'fiche', 'secretaire');
select set_config('test.fiche', :'fiche', false);
select pg_temp.connecte(:'a');
set local role authenticated;
do $$ begin
  -- Sans NimbaSMS (essai) : refus clair, aucun code créé.
  begin
    perform public.envoyer_invitation_sms(current_setting('test.fiche')::uuid);
    raise exception 'ÉCHEC : envoi sans configuration accepté';
  exception when sqlstate '55000' then null;
  end;
end $$;
reset role;
insert into scolagrid.reglages (cle, valeur) values ('nimba_service_id', 'x'), ('nimba_secret_token', 'y')
  on conflict (cle) do update set valeur = excluded.valeur;
-- Trois SMS déjà partis aujourd'hui : le quatrième est refusé (avant tout envoi).
insert into public.invitations (organisation_id, personnel_id, code, expire_le, annulee_le, sms_envoye_le)
  select :'org', :'fiche', 'TESTSM' || n || 'X', now() + interval '7 days', now(), now() from generate_series(1, 3) n;
set local role authenticated;
do $$ begin
  begin
    perform public.envoyer_invitation_sms(current_setting('test.fiche')::uuid);
    raise exception 'ÉCHEC : quatrième SMS du jour accepté';
  exception when sqlstate '54000' then null;
  end;
end $$;
reset role;
select 'Test 031 : tout est conforme.';
rollback;
