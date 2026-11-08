-- Test de la migration 039 : masquer une page n'ajoute ni ne retire aucun droit.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set u '33333333-0000-0000-0000-000000000039'
begin;
insert into auth.users (id, aud, role, phone) values (:'u', 'authenticated', 'authenticated', '224620000039');
select id as org from public.organisations where cree_par = :'a' order by created_at limit 1 \gset
insert into public.personnel (organisation_id, nom_complet, telephone) values (:'org', 'Caissier Test', '224620000039') returning id as fiche \gset
insert into public.affectations (organisation_id, personnel_id, fonction) values (:'org', :'fiche', 'caissier');
update public.personnel set user_id = :'u' where id = :'fiche';
select set_config('test.u', :'u', false);

select lit_caisse as avant from public.rattachements where user_id = :'u' and role = 'caissier' \gset
insert into public.droits_personnel (organisation_id, personnel_id, droit, accorde) values
  (:'org', :'fiche', 'masquer_depenses', true), (:'org', :'fiche', 'masquer_familles', true);
do $$ begin
  assert (select lit_caisse from public.rattachements where user_id = current_setting('test.u')::uuid and role = 'caissier'),
    'Masquer une page ne retire pas la lecture de la caisse';
end $$;

-- Une page inconnue est refusée.
do $$ begin
  insert into public.droits_personnel (organisation_id, personnel_id, droit, accorde)
    select organisation_id, id, 'masquer_nimporte', true from public.personnel where telephone = '224620000039';
  assert false, 'Page inconnue acceptée';
exception when check_violation then null;
end $$;
rollback;
