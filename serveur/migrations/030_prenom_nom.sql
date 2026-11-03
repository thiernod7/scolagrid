-- 030 : prénom(s) et nom séparés pour le personnel et les parents.
--
-- nom_complet reste la colonne affichée partout (« Mamadou Saliou DIALLO ») ;
-- l'application le compose à partir des deux champs. Les fiches plus anciennes
-- (ou un parent importé d'un registre) n'ont que nom_complet.

alter table public.personnel
  add column prenoms text check (prenoms is null or length(trim(prenoms)) between 1 and 80),
  add column nom text check (nom is null or length(trim(nom)) between 1 and 60);

alter table public.contacts
  add column prenoms text check (prenoms is null or length(trim(prenoms)) between 1 and 80),
  add column nom text check (nom is null or length(trim(nom)) between 1 and 60);

-- Création d'espace : le fondateur donne aussi son prénom et son nom séparés.
-- Les anciens appels (quatre paramètres) restent acceptés.
drop function public.creer_espace_ecole(text, text, text, text);
create function public.creer_espace_ecole(
  nom_groupe text, ville text, nom_site text, nom_complet text, prenoms text default null, nom text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  tel text;
  org uuid;
  fiche uuid;
begin
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  if (select count(*) from public.organisations where cree_par = moi) >= 5 then
    raise exception 'Trop d''espaces créés avec ce compte' using errcode = '54000';
  end if;
  select phone into tel from auth.users where id = moi;

  insert into public.personnes (id, nom_complet, telephone)
  values (moi, trim(nom_complet), tel)
  on conflict (id) do update set nom_complet = excluded.nom_complet;

  insert into public.organisations (nom, ville, cree_par)
  values (trim(nom_groupe), trim(ville), moi)
  returning id into org;

  insert into public.sites (organisation_id, nom, ville)
  values (org, trim(nom_site), trim(ville));

  insert into public.personnel (organisation_id, nom_complet, prenoms, nom, telephone, user_id)
  values (org, trim(nom_complet), nullif(trim(prenoms), ''), nullif(upper(trim(nom)), ''), tel, moi)
  returning id into fiche;

  -- Le rattachement « fondateur » est créé par le calcul des accès.
  insert into public.affectations (organisation_id, personnel_id, fonction)
  values (org, fiche, 'fondateur');

  return org;
end $$;
