-- Test de la migration 028 : pas deux classes ouvertes du même nom ; jeux d'options du lycée.
\set ON_ERROR_STOP on
\set ins '10000000-0000-0000-0000-000000000001'

begin;
select c.organisation_id as org, c.site_id as site, c.annee_id as annee, c.niveau_id as niveau, 'Test 028 A' as nom
  from public.inscriptions i join public.classes c on c.id = i.classe_id where i.id = :'ins' \gset
select set_config('test.org', :'org', false), set_config('test.site', :'site', false), set_config('test.annee', :'annee', false),
       set_config('test.niveau', :'niveau', false), set_config('test.nom', :'nom', false);

insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom) values (:'org', :'site', :'annee', :'niveau', :'nom');
do $$ begin
  begin
    -- Même nom, à la casse et aux espaces près.
    insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom)
      values (current_setting('test.org')::uuid, current_setting('test.site')::uuid, current_setting('test.annee')::uuid,
              current_setting('test.niveau')::uuid, '  ' || upper(replace(current_setting('test.nom'), ' ', '  ')));
    raise exception 'ÉCHEC : deuxième classe du même nom acceptée';
  exception when unique_violation then null;
  end;
  begin
    update public.niveaux set series = 'SM,SE,SS,SL' where id = current_setting('test.niveau')::uuid;
    raise exception 'ÉCHEC : jeu d''options mélangé accepté';
  exception when check_violation then null;
  end;
  update public.niveaux set series = 'SS,SL' where id = current_setting('test.niveau')::uuid;
  update public.niveaux set series = 'SM,SS,SE' where id = current_setting('test.niveau')::uuid;
end $$;

-- Une classe fermée libère son nom.
update public.classes set fermee = true where nom = :'nom' and site_id = :'site' and annee_id = :'annee';
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom) values (:'org', :'site', :'annee', :'niveau', :'nom');
select 'ok 028';
rollback;
