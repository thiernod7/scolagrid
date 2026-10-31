-- Test de la migration 004, joué par GitHub sur une base jetable, après 002 et 003.
-- A : fondateur (deux sites). B : fondateur d'une autre école.
-- D : invité comme directeur du site 1. E : invité comme enseignant. F : un inconnu.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set d '44444444-4444-4444-4444-444444444444'
\set e '55555555-5555-5555-5555-555555555555'
\set f '66666666-6666-6666-6666-666666666666'

insert into auth.users (id, aud, role, phone) values
  (:'d', 'authenticated', 'authenticated', '224620000004'),
  (:'e', 'authenticated', 'authenticated', '224620000005'),
  (:'f', 'authenticated', 'authenticated', '224620000006');

-- Se connecter comme une personne, pour la transaction en cours.
create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as site_1 from public.sites where organisation_id = :'org_a' and nom = 'Site de Kaloum' \gset
select id as site_2 from public.sites where organisation_id = :'org_a' and nom = 'Site de Ratoma' \gset
select set_config('test.org', :'org_a', false), set_config('test.site_1', :'site_1', false),
       set_config('test.site_2', :'site_2', false);

-- La création d'espace a donné une fiche au fondateur A
do $$ begin
  assert (select count(*) from public.personnel p join public.affectations f on f.personnel_id = p.id
          where p.user_id = '11111111-1111-1111-1111-111111111111' and f.fonction = 'fondateur') = 1,
         'A doit avoir une fiche de fondateur';
end $$;

-- A crée la fiche d'un directeur pour le site 1, et celle du gardien (sans compte)
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.personnel (organisation_id, site_id, nom_complet, telephone, user_id)
  values (:'org_a', :'site_1', 'Mamadou Diallo', '620 00 00 04', :'b') returning id as fiche_d \gset
insert into public.affectations (organisation_id, personnel_id, site_id, fonction) values (:'org_a', :'fiche_d', :'site_1', 'directeur');
insert into public.personnel (organisation_id, site_id, nom_complet) values (:'org_a', :'site_1', 'Alpha Gardien') returning id as fiche_g \gset
insert into public.affectations (organisation_id, personnel_id, site_id, fonction, libelle) values (:'org_a', :'fiche_g', :'site_1', 'autre', 'Gardien');
select public.inviter_personnel(:'fiche_d') as code_d \gset
commit;
select set_config('test.fiche_d', :'fiche_d', false), set_config('test.code_d', :'code_d', false);
do $$ begin
  assert (select user_id from public.personnel where id = current_setting('test.fiche_d')::uuid) is null,
         'L''app ne doit pas pouvoir choisir le compte d''une fiche';
  assert current_setting('test.code_d') ~ '^[A-Z0-9]{8}$', 'Le code doit faire 8 signes';
end $$;

-- D se connecte : un code faux ne donne rien, le bon code le relie à sa fiche
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
do $$ begin
  assert public.accepter_invitation('AAAA-AAAA') is null, 'Un code faux ne doit rien donner';
  assert public.accepter_invitation(lower(substr(current_setting('test.code_d'), 1, 4)) || '-' || substr(current_setting('test.code_d'), 5))
         = current_setting('test.org')::uuid, 'Le bon code (minuscules, tiret) doit être accepté';
  assert (select count(*) from public.rattachements where user_id = auth.uid() and role = 'directeur' and actif) = 1, 'D doit être directeur';
  -- D voit les fiches de son site (la sienne, le gardien), pas celle du fondateur
  assert (select count(*) from public.personnel) = 2, 'D doit voir les 2 fiches du site 1';
end $$;
commit;

-- Le code ne sert qu'une fois
begin;
select pg_temp.connecte(:'f');
set local role authenticated;
do $$ begin
  assert public.accepter_invitation(current_setting('test.code_d')) is null, 'Un code déjà utilisé doit être refusé';
end $$;
commit;

-- D, directeur du site 1, ajoute un enseignant et l'invite ; ses limites
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
insert into public.personnel (organisation_id, site_id, nom_complet, telephone)
  values (:'org_a', :'site_1', 'Fatoumata Bah', '+224 620 00 00 05') returning id as fiche_e \gset
insert into public.affectations (organisation_id, personnel_id, site_id, fonction) values (:'org_a', :'fiche_e', :'site_1', 'enseignant');
select public.inviter_personnel(:'fiche_e') as code_e \gset
select set_config('test.fiche_e', :'fiche_e', true);
do $$ begin
  begin
    insert into public.affectations (organisation_id, personnel_id, site_id, fonction)
      values (current_setting('test.org')::uuid, current_setting('test.fiche_e')::uuid, current_setting('test.site_1')::uuid, 'directeur');
    raise exception 'D a pu nommer un directeur';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.affectations (organisation_id, personnel_id, site_id, fonction)
      values (current_setting('test.org')::uuid, current_setting('test.fiche_e')::uuid, current_setting('test.site_2')::uuid, 'enseignant');
    raise exception 'D a pu donner une fonction sur le site 2';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.droits_personnel (organisation_id, personnel_id, droit, accorde)
      values (current_setting('test.org')::uuid, current_setting('test.fiche_e')::uuid, 'valider_paie', true);
    raise exception 'D a pu accorder un droit';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.inviter_personnel((select id from public.personnel where user_id = current_setting('request.jwt.claim.sub')::uuid));
    raise exception 'D a pu inviter une fiche qui a déjà un compte';
  exception when invalid_parameter_value then null;
  end;
end $$;
-- Le fondateur est hors de son périmètre : modification ignorée, invitation refusée
update public.personnel set nom_complet = 'Piraté' where user_id = :'a';
commit;
select set_config('test.fiche_e', :'fiche_e', false), set_config('test.code_e', :'code_e', false);
do $$ begin
  assert (select count(*) from public.personnel where nom_complet = 'Piraté') = 0, 'D ne doit pas modifier la fiche du fondateur';
end $$;

-- F essaie le code destiné au numéro de E : refusé
begin;
select pg_temp.connecte(:'f');
set local role authenticated;
do $$ begin
  begin
    perform public.accepter_invitation(current_setting('test.code_e'));
    raise exception 'F a utilisé un code destiné à un autre numéro';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- E utilise son code : enseignant du site 1, avec les droits par défaut
begin;
select pg_temp.connecte(:'e');
set local role authenticated;
do $$
declare org uuid := current_setting('test.org')::uuid; s1 uuid := current_setting('test.site_1')::uuid;
begin
  assert public.accepter_invitation(current_setting('test.code_e')) = org, 'E doit pouvoir entrer';
  assert (select count(*) from public.personnel) = 1, 'E ne doit voir que sa fiche';
  assert scolagrid.a_le_droit(org, s1, 'saisir_notes'), 'Un enseignant saisit les notes';
  assert scolagrid.a_le_droit(org, s1, 'faire_appel'), 'Un enseignant fait l''appel';
  assert not scolagrid.a_le_droit(org, s1, 'valider_paie'), 'La paie n''est jamais automatique';
  assert not scolagrid.a_le_droit(org, current_setting('test.site_2')::uuid, 'saisir_notes'), 'Pas de droit sur le site 2';
end $$;
update public.personnel set statut = 'sorti';   -- ignoré : E ne gère pas sa fiche
commit;
do $$ begin
  assert (select statut from public.personnel where id = current_setting('test.fiche_e')::uuid) = 'actif', 'E ne doit pas modifier sa fiche';
end $$;

-- A ajuste les droits de E : retire l'appel, accorde la préparation de la paie
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.droits_personnel (organisation_id, personnel_id, site_id, droit, accorde) values
  (:'org_a', :'fiche_e', null, 'faire_appel', false),
  (:'org_a', :'fiche_e', :'site_1', 'preparer_paie', true);
commit;
begin;
select pg_temp.connecte(:'e');
set local role authenticated;
do $$
declare org uuid := current_setting('test.org')::uuid; s1 uuid := current_setting('test.site_1')::uuid;
begin
  assert not scolagrid.a_le_droit(org, s1, 'faire_appel'), 'Le droit retiré ne doit plus marcher';
  assert scolagrid.a_le_droit(org, s1, 'preparer_paie'), 'Le droit accordé doit marcher';
  assert (select count(*) from public.droits_personnel) = 2, 'E doit voir ses droits particuliers';
end $$;
commit;

-- D enregistre le départ de E : E perd l'accès
begin;
select pg_temp.connecte(:'d');
set local role authenticated;
update public.personnel set statut = 'sorti' where id = :'fiche_e';
commit;
do $$ begin
  assert (select count(*) from public.rattachements
          where user_id = '55555555-5555-5555-5555-555555555555' and actif) = 0, 'E ne doit plus avoir accès';
end $$;

-- A ne peut pas retirer le dernier fondateur
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
do $$ begin
  begin
    update public.affectations set actif = false where fonction = 'fondateur';
    raise exception 'Le dernier fondateur a pu être retiré';
  exception when check_violation then null;
  end;
end $$;
commit;

-- Essais au hasard : bloqués après 10 codes faux en une heure
begin;
select pg_temp.connecte(:'f');
set local role authenticated;
do $$ begin
  -- F a déjà essayé un code déjà utilisé : 9 essais de plus font 10.
  for i in 1..9 loop perform public.accepter_invitation('ZZZZZZZ' || i); end loop;
  begin
    perform public.accepter_invitation('ZZZZZZZZ');
    raise exception 'Les essais au hasard ne sont pas bloqués';
  exception when program_limit_exceeded then null;
  end;
end $$;
commit;

-- B ne voit rien du personnel de A
begin;
select pg_temp.connecte(:'b');
set local role authenticated;
do $$ begin
  assert (select count(*) from public.personnel where organisation_id = current_setting('test.org')::uuid) = 0, 'B ne doit voir aucune fiche de A';
  assert (select count(*) from public.affectations where organisation_id = current_setting('test.org')::uuid) = 0, 'B ne doit voir aucune fonction de A';
  assert (select count(*) from public.invitations) = 0, 'B ne doit voir aucune invitation de A';
  begin
    perform public.inviter_personnel(current_setting('test.fiche_d')::uuid);
    raise exception 'B a pu inviter chez A';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

\echo 'Test 004 : tout est conforme.'
