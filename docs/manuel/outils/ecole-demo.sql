-- École de démonstration (fictive) pour les captures du manuel, sur l'ESSAI seulement.
-- Variable psql : tel (numéro de test, ex. 224620000004). Rejouable : ne refait rien si l'école existe.
\set ON_ERROR_STOP on
begin;
select id as moi from auth.users where phone = :'tel' \gset
select set_config('request.jwt.claims', json_build_object('sub', :'moi', 'role', 'authenticated', 'is_anonymous', false)::text, true) as c1,
       set_config('request.jwt.claim.sub', :'moi', true) as c2 \gset
select count(*) filter (where nom <> 'Groupe scolaire Les Manguiers') > 0 as autre from public.organisations where cree_par = :'moi' \gset
\if :autre
  \echo 'Ce numéro de test a déjà une autre école : rien n''est fait.'
  rollback;
  \quit
\endif
select count(*) > 0 as deja from public.organisations where cree_par = :'moi' \gset
\if :deja
  \echo 'École de démonstration déjà prête.'
  rollback;
  \quit
\endif
select public.creer_espace_ecole('Groupe scolaire Les Manguiers', 'Conakry', 'Site de Kipé', 'Aïssatou CAMARA', 'Aïssatou', 'Camara') as org \gset
select id as site from public.sites where organisation_id = :'org' \gset
update public.organisations set code = 'GSM', nom_officiel = 'Groupe scolaire privé Les Manguiers', telephone = '620 00 00 04',
  quartier = 'Kipé', responsable_nom = 'Aïssatou CAMARA', responsable_titre = 'Fondatrice' where id = :'org';
update public.sites set code = 'KIP', quartier = 'Kipé' where id = :'site';

insert into public.annees_scolaires (organisation_id, libelle, debut, fin, en_cours, periodicite, nb_mois, etat)
  values (:'org', '2026-2027', '2026-10-01', '2027-06-30', true, 'tranches', 9, 'inscriptions') returning id as annee \gset
insert into public.tranches_annee (organisation_id, annee_id, ordre, libelle, date_limite, part) values
  (:'org', :'annee', 1, '1re tranche', '2026-10-31', 40),
  (:'org', :'annee', 2, '2e tranche', '2027-01-31', 30),
  (:'org', :'annee', 3, '3e tranche', '2027-04-30', 30);

select set_config('demo.org', :'org', true) as d1, set_config('demo.annee', :'annee', true) as d2,
       set_config('demo.site', :'site', true) as d3 \gset
create temp table n (cycle text, nom text, ordre int, usage text, examen text, ins bigint, sco bigint) on commit drop;
insert into n values
  ('primaire', 'CP1', 4, '1ère année', null, 150000, 1200000),
  ('primaire', 'CE2', 7, '4ème année', null, 150000, 1350000),
  ('primaire', 'CM2', 9, '6ème année', 'CEE', 150000, 1500000),
  ('college', '7ème', 10, '7ème année', null, 200000, 1800000),
  ('college', '10ème', 13, '10ème année', 'BEPC', 200000, 2100000);
do $$
declare r record; niv uuid; f uuid; org uuid := current_setting('demo.org')::uuid; an uuid := current_setting('demo.annee')::uuid;
        site uuid := current_setting('demo.site')::uuid; l text;
begin
  for r in select * from n order by ordre loop
    insert into public.niveaux (organisation_id, cycle, nom, ordre, nom_usage, examen, niveau_final)
      values (org, r.cycle, r.nom, r.ordre, r.usage, r.examen, r.nom = '10ème') returning id into niv;
    foreach l in array array['A', 'B'] loop
      insert into public.classes (organisation_id, site_id, annee_id, niveau_id, nom, lettre, capacite)
        values (org, site, an, niv, r.nom || ' ' || l, l, 45);
    end loop;
    insert into public.frais (organisation_id, annee_id, niveau_id, libelle, montant_gnf, periodicite, type_frais)
      values (org, an, niv, 'Inscription', r.ins, 'unique', 'inscription');
    insert into public.frais (organisation_id, annee_id, niveau_id, libelle, montant_gnf, periodicite, type_frais)
      values (org, an, niv, 'Réinscription', r.ins - 50000, 'unique', 'reinscription');
    insert into public.frais (organisation_id, annee_id, niveau_id, libelle, montant_gnf, periodicite, type_frais)
      values (org, an, niv, 'Scolarité', r.sco, 'tranches', 'scolarite') returning id into f;
    insert into public.echeances (organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite) values
      (org, f, 1, '1re tranche', r.sco * 40 / 100, '2026-10-31'),
      (org, f, 2, '2e tranche', r.sco * 30 / 100, '2027-01-31'),
      (org, f, 3, '3e tranche', r.sco - r.sco * 70 / 100, '2027-04-30');
  end loop;
end $$;
commit;
\echo 'École de démonstration créée.'
