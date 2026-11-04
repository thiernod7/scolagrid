-- Test de la migration 032 : autres frais obligatoires ou réservés à des classes.
\set ON_ERROR_STOP on
begin;
select f.organisation_id as org, f.annee_id as annee, c.id as classe, c.niveau_id as niveau
  from public.frais f join public.classes c on c.annee_id = f.annee_id limit 1 \gset
insert into public.frais (organisation_id, annee_id, niveau_id, libelle, montant_gnf, periodicite, type_frais, obligatoire, classes)
  values (:'org', :'annee', :'niveau', 'Internat', 900000, 'tranches', 'optionnel', true, :'classe');
select set_config('test.org', :'org', false), set_config('test.annee', :'annee', false);
do $$ begin
  begin
    insert into public.frais (organisation_id, annee_id, libelle, montant_gnf, periodicite, type_frais, classes)
      values (current_setting('test.org')::uuid, current_setting('test.annee')::uuid, 'Cantine', 100, 'unique', 'optionnel', 'pas-une-classe');
    raise exception 'ÉCHEC : liste de classes invalide acceptée';
  exception when check_violation then null;
  end;
  begin
    insert into public.frais (organisation_id, annee_id, libelle, montant_gnf, periodicite, type_frais, obligatoire)
      values (current_setting('test.org')::uuid, current_setting('test.annee')::uuid, 'Inscription bis', 100, 'unique', 'inscription', true);
    raise exception 'ÉCHEC : « obligatoire » sur un frais d''inscription accepté';
  exception when check_violation then null;
  end;
end $$;
select 'Test 032 : tout est conforme.';
rollback;
