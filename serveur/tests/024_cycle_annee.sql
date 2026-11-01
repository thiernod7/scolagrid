-- Test de la migration 024 : cycle de vie de l'année scolaire.
-- A : fondateur. S : secrétaire du site 1.

\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set s '88888888-8888-8888-8888-888888888888'

create function pg_temp.connecte(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', false)::text, true);
  select set_config('request.jwt.claim.sub', u::text, true);
$$;

select id as org_a from public.organisations where cree_par = :'a' \gset
select id as courante, fin from public.annees_scolaires where organisation_id = :'org_a' and en_cours \gset
select i.eleve_id as eleve, i.site_id as site, c.niveau_id as niveau
  from public.inscriptions i join public.classes c on c.id = i.classe_id where i.annee_id = :'courante' limit 1 \gset
select set_config('test.org', :'org_a', false), set_config('test.courante', :'courante', false),
       set_config('test.eleve', :'eleve', false), set_config('test.site', :'site', false), set_config('test.niveau', :'niveau', false);

do $$ begin
  assert (select etat from public.annees_scolaires where id = current_setting('test.courante')::uuid) = 'en_cours', 'L''année en cours est « en cours »';
end $$;

-- Le fondateur prépare l'année suivante.
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
insert into public.annees_scolaires (organisation_id, libelle, debut, fin)
  values (:'org_a', 'Prochaine', :'fin'::date + 70, :'fin'::date + 360) returning id as prochaine \gset
insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom)
  values (:'org_a', :'site', :'prochaine', :'niveau', 'Classe prochaine') returning id as classe_p \gset
commit;
select set_config('test.prochaine', :'prochaine', false), set_config('test.classe_p', :'classe_p', false);

-- En préparation : pas d'inscription.
do $$ begin
  assert (select etat from public.annees_scolaires where id = current_setting('test.prochaine')::uuid) = 'preparation', 'En préparation';
  begin
    insert into public.inscriptions (organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission)
      values (current_setting('test.org')::uuid, current_setting('test.eleve')::uuid, current_setting('test.prochaine')::uuid,
              current_setting('test.site')::uuid, current_setting('test.classe_p')::uuid, 'reinscription');
    raise exception 'Inscription dans une année en préparation';
  exception when check_violation then null;
  end;
  -- Deux années en cours : refusé.
  begin
    update public.annees_scolaires set etat = 'en_cours' where id = current_setting('test.prochaine')::uuid;
    raise exception 'Deux années en cours';
  exception when unique_violation then null;
  end;
end $$;

-- Inscriptions ouvertes : la réinscription passe.
update public.annees_scolaires set etat = 'inscriptions' where id = :'prochaine';
insert into public.inscriptions (organisation_id, eleve_id, annee_id, site_id, classe_id, type_admission)
  values (:'org_a', :'eleve', :'prochaine', :'site', :'classe_p', 'reinscription') returning id as reins \gset
select set_config('test.reins', :'reins', false);

-- On ne revient pas en arrière.
do $$ begin
  begin
    update public.annees_scolaires set etat = 'preparation' where id = current_setting('test.prochaine')::uuid;
    raise exception 'Retour en arrière accepté';
  exception when check_violation then null;
  end;
end $$;

-- Bascule : clôturer l'année en cours, démarrer la suivante (comme le fait l'app).
begin;
select pg_temp.connecte(:'a');
set local role authenticated;
update public.annees_scolaires set etat = 'cloturee' where id = :'courante';
update public.annees_scolaires set etat = 'en_cours' where id = :'prochaine';
commit;
do $$ begin
  assert not (select en_cours from public.annees_scolaires where id = current_setting('test.courante')::uuid), 'L''ancienne n''est plus en cours';
  assert (select cloturee_le from public.annees_scolaires where id = current_setting('test.courante')::uuid) is not null, 'Date de clôture';
  assert (select en_cours from public.annees_scolaires where id = current_setting('test.prochaine')::uuid), 'La nouvelle est en cours';
  -- Année clôturée : lecture seule.
  begin
    update public.classes set salle = 'Salle 9' where annee_id = current_setting('test.courante')::uuid;
    raise exception 'Classe modifiée dans une année clôturée';
  exception when check_violation then null;
  end;
  begin
    update public.frais set montant_gnf = montant_gnf + 1, motif_correction = 'Essai' where annee_id = current_setting('test.courante')::uuid;
    raise exception 'Frais modifié dans une année clôturée';
  exception when check_violation then null;
  end;
  begin
    update public.annees_scolaires set fin = fin + 1 where id = current_setting('test.courante')::uuid;
    raise exception 'Dates d''une année clôturée modifiées';
  exception when check_violation then null;
  end;
  begin
    update public.inscriptions set classe_id = current_setting('test.classe_p')::uuid
      where annee_id = current_setting('test.courante')::uuid and eleve_id = current_setting('test.eleve')::uuid;
    raise exception 'Élève déplacé dans une année clôturée';
  exception when check_violation then null;
  end;
end $$;

-- Mais les arriérés s'encaissent, et le statut se note encore.
select id as ins_ancienne from public.inscriptions where annee_id = :'courante' and eleve_id = :'eleve' \gset
select statut as statut_avant from public.inscriptions where id = :'ins_ancienne' \gset
update public.inscriptions set statut = 'diplome' where id = :'ins_ancienne';
update public.inscriptions set statut = :'statut_avant', date_sortie = null where id = :'ins_ancienne';

-- Ménage : remettre l'année d'origine en cours (en contournant le cycle, pour les tests suivants).
alter table public.annees_scolaires disable trigger annee_cycle;
delete from public.inscriptions where id = :'reins';
delete from public.classes where id = :'classe_p';
delete from public.annees_scolaires where id = :'prochaine';
update public.annees_scolaires set etat = 'en_cours', en_cours = true, cloturee_le = null where id = :'courante';
alter table public.annees_scolaires enable trigger annee_cycle;
\echo 'Test 024 : tout est conforme.'
