-- 007 : élèves, parents (contacts) et inscriptions.
--
-- Élève : identité permanente, avec un matricule créé hors ligne par le poste
-- (sigle-site-année-lettre du poste + numéro), définitif. Le site du matricule
-- est le site d'origine ; le site actuel est un champ à part.
-- Contacts : parents, tuteurs… partagés entre frères et sœurs. Sur chaque lien
-- élève-contact : tuteur principal (communications) et responsable financier
-- (qui paie, sert à la réduction fratrie), un seul de chaque par élève.
-- Inscription : un élève, une année, une classe, un statut. On n'efface rien :
-- on annule, et chaque changement de classe ou de statut est historisé.

-- Droits : inscrire et encaisser --------------------------------------------------

alter table public.droits_personnel drop constraint droits_personnel_droit_check;
alter table public.droits_personnel add constraint droits_personnel_droit_check check (droit in (
  'valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps', 'planifier_evaluations',
  'saisir_notes', 'faire_appel', 'justifier_absence', 'preparer_paie', 'valider_paie',
  'verser_paie', 'consulter_tableau_bord', 'autoriser_depense',
  'gerer_inscriptions', 'encaisser'));

create or replace function scolagrid.droits_par_defaut(fonction text) returns text[]
language sql immutable set search_path = '' as $$
  select case fonction
    when 'directeur' then array['valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
                                'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord',
                                'gerer_inscriptions']
    when 'directeur_etudes' then array['gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence']
    when 'surveillant' then array['faire_appel', 'justifier_absence']
    when 'enseignant' then array['saisir_notes', 'faire_appel']
    when 'secretaire' then array['gerer_inscriptions', 'encaisser']
    when 'comptable' then array['consulter_tableau_bord', 'gerer_inscriptions', 'encaisser']
    when 'caissier' then array['encaisser']
    else array[]::text[]
  end
$$;

-- Ce droit, sur au moins un site de l'organisation (ou sur tout le groupe) ?
create or replace function scolagrid.a_le_droit_quelque_part(org uuid, quel_droit text) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.a_le_droit(org, null, quel_droit)
      or exists (select 1 from public.sites s where s.organisation_id = org and scolagrid.a_le_droit(org, s.id, quel_droit))
$$;
revoke all on function scolagrid.a_le_droit_quelque_part(uuid, text) from public;
grant execute on function scolagrid.a_le_droit_quelque_part(uuid, text) to authenticated;

-- Tables ----------------------------------------------------------------------------

alter table public.classes add constraint classes_id_organisation_unique unique (id, organisation_id);

create table public.eleves (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  matricule text not null unique
    check (matricule ~ '^[A-Z0-9]{2,10}-[A-Z0-9]{2,10}-[0-9]{4}-[A-Z]{1,3}[0-9]{3,6}$'),
  matricule_etat text check (matricule_etat is null or length(trim(matricule_etat)) between 1 and 40),
  site_origine_id uuid not null,
  site_id uuid not null,                       -- site actuel
  nom text not null check (length(trim(nom)) between 1 and 80),
  prenoms text not null check (length(trim(prenoms)) between 1 and 120),
  sexe text check (sexe in ('M', 'F')),
  date_naissance date check (date_naissance is null or date_naissance > '1980-01-01'),
  lieu_naissance text check (lieu_naissance is null or length(lieu_naissance) <= 80),
  nationalite text check (nationalite is null or length(nationalite) <= 40),
  quartier text check (quartier is null or length(quartier) <= 80),
  allergies text check (allergies is null or length(allergies) <= 200),
  sante text check (sante is null or length(sante) <= 300),          -- traitement, condition
  groupe_sanguin text check (groupe_sanguin is null or groupe_sanguin in ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')),
  ecole_precedente text check (ecole_precedente is null or length(ecole_precedente) <= 120),
  date_premiere_inscription date not null default current_date,
  poste_id uuid references public.postes (id) on delete set null,
  cree_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id),
  foreign key (site_origine_id, organisation_id) references public.sites (id, organisation_id),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id)
);
create unique index eleves_matricule_etat_unique on public.eleves (organisation_id, matricule_etat)
  where matricule_etat is not null;
create index eleves_nom_idx on public.eleves (organisation_id, nom);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  nom_complet text not null check (length(trim(nom_complet)) between 2 and 120),
  telephone text check (telephone is null or telephone ~ '^\+?[0-9 ]{8,20}$'),
  telephone2 text check (telephone2 is null or telephone2 ~ '^\+?[0-9 ]{8,20}$'),
  email text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  profession text check (profession is null or length(profession) <= 80),
  adresse text check (adresse is null or length(adresse) <= 160),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id)
);
create index contacts_telephone_idx on public.contacts (organisation_id, telephone);

create table public.eleves_contacts (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  eleve_id uuid not null,
  contact_id uuid not null,
  lien text not null check (lien in ('pere', 'mere', 'tuteur', 'oncle', 'tante', 'grand_parent', 'frere_soeur', 'autre')),
  tuteur_principal boolean not null default false,
  responsable_financier boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (eleve_id, contact_id),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id) on delete cascade,
  foreign key (contact_id, organisation_id) references public.contacts (id, organisation_id) on delete cascade
);
create unique index un_tuteur_principal on public.eleves_contacts (eleve_id) where tuteur_principal;
create unique index un_responsable_financier on public.eleves_contacts (eleve_id) where responsable_financier;
create index eleves_contacts_contact_idx on public.eleves_contacts (contact_id);

create table public.inscriptions (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  eleve_id uuid not null,
  annee_id uuid not null,
  site_id uuid not null,
  classe_id uuid not null,
  type_admission text not null check (type_admission in ('nouvelle', 'reinscription', 'transfert')),
  statut text not null default 'en_attente' check (statut in (
    'en_attente', 'actif', 'suspendu', 'annule', 'exclu', 'transfert_sortant', 'diplome')),
  date_effective date not null default current_date,   -- date réelle d'arrivée (échéancier)
  date_actif date,
  date_sortie date,
  motif text check (motif is null or length(motif) <= 300),
  poste_id uuid references public.postes (id) on delete set null,
  cree_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),             -- date de saisie, immuable
  updated_at timestamptz not null default now(),
  unique (eleve_id, annee_id),
  unique (id, organisation_id),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id),
  foreign key (annee_id, organisation_id) references public.annees_scolaires (id, organisation_id),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id),
  foreign key (classe_id, organisation_id) references public.classes (id, organisation_id)
);
create index inscriptions_classe_idx on public.inscriptions (classe_id);
create index inscriptions_annee_idx on public.inscriptions (annee_id);

-- Historique : rempli par le serveur, lu par l'app.
create table public.historique_eleves (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  eleve_id uuid not null,
  inscription_id uuid,
  evenement text not null check (evenement in ('inscription', 'mutation', 'statut')),
  de_classe_id uuid,
  vers_classe_id uuid,
  ancien_statut text,
  nouveau_statut text,
  motif text,
  par uuid references auth.users (id) on delete set null,
  quand timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id) on delete cascade
);
create index historique_eleve_idx on public.historique_eleves (eleve_id);

do $$
declare t text;
begin
  foreach t in array array['eleves', 'contacts', 'eleves_contacts', 'inscriptions', 'historique_eleves'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I
                    for each row execute function scolagrid.maj_updated_at()', t);
    execute format('create trigger organisation_immuable before update on public.%I
                    for each row execute function scolagrid.organisation_immuable()', t);
  end loop;
end $$;

-- Champs verrouillés ------------------------------------------------------------------

create or replace function scolagrid.eleve_protege() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated', 'anon') then
      new.cree_par := auth.uid();
    end if;
    return new;
  end if;
  new.matricule := old.matricule;
  new.site_origine_id := old.site_origine_id;
  new.date_premiere_inscription := old.date_premiere_inscription;
  new.poste_id := old.poste_id;
  new.cree_par := old.cree_par;
  new.created_at := old.created_at;
  return new;
end $$;
create trigger eleve_protege before insert or update on public.eleves
  for each row execute function scolagrid.eleve_protege();

-- Une inscription vise une classe de la même année et du même site ; l'élève,
-- l'année et le type d'admission ne changent plus.
create or replace function scolagrid.inscription_controlee() returns trigger
language plpgsql set search_path = '' as $$
declare c public.classes;
begin
  if tg_op = 'UPDATE' then
    new.eleve_id := old.eleve_id;
    new.annee_id := old.annee_id;
    new.type_admission := old.type_admission;
    new.created_at := old.created_at;
    new.cree_par := old.cree_par;
    new.poste_id := old.poste_id;
  elsif current_user in ('authenticated', 'anon') then
    new.cree_par := auth.uid();
  end if;
  select * into c from public.classes where id = new.classe_id;
  if c.annee_id <> new.annee_id or c.site_id <> new.site_id then
    raise exception 'La classe doit être de la même année et du même site' using errcode = '23514';
  end if;
  if new.statut in ('annule', 'exclu', 'transfert_sortant', 'diplome') and new.date_sortie is null then
    new.date_sortie := current_date;
  end if;
  return new;
end $$;
create trigger inscription_controlee before insert or update on public.inscriptions
  for each row execute function scolagrid.inscription_controlee();

-- Historique des inscriptions, changements de classe et de statut.
create or replace function scolagrid.historiser_inscription() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.historique_eleves (organisation_id, eleve_id, inscription_id, evenement, vers_classe_id, nouveau_statut, par)
    values (new.organisation_id, new.eleve_id, new.id, 'inscription', new.classe_id, new.statut, auth.uid());
  else
    if new.classe_id is distinct from old.classe_id then
      insert into public.historique_eleves (organisation_id, eleve_id, inscription_id, evenement, de_classe_id, vers_classe_id, par)
      values (new.organisation_id, new.eleve_id, new.id, 'mutation', old.classe_id, new.classe_id, auth.uid());
      -- Le site actuel de l'élève suit sa classe.
      update public.eleves set site_id = new.site_id where id = new.eleve_id and site_id is distinct from new.site_id;
    end if;
    if new.statut is distinct from old.statut then
      insert into public.historique_eleves (organisation_id, eleve_id, inscription_id, evenement, ancien_statut, nouveau_statut, motif, par)
      values (new.organisation_id, new.eleve_id, new.id, 'statut', old.statut, new.statut, new.motif, auth.uid());
    end if;
  end if;
  return null;
end $$;
create trigger historiser_inscription after insert or update on public.inscriptions
  for each row execute function scolagrid.historiser_inscription();
revoke all on function scolagrid.historiser_inscription() from public;

-- Règles d'accès ------------------------------------------------------------------------

-- Élèves et inscriptions : lus par tous les membres (listes de classe) ;
-- écrits par ceux qui ont le droit « gerer_inscriptions » sur le site.
grant select, insert, update, delete on public.eleves to authenticated;
create policy "membres lisent" on public.eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "inscripteur ajoute" on public.eleves for insert to authenticated
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'));
create policy "inscripteur modifie" on public.eleves for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'))
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'));
-- Fiche créée par erreur : seul le fondateur la supprime, et seulement sans inscription.
create policy "fondateur supprime une fiche vide" on public.eleves for delete to authenticated
  using (scolagrid.est_fondateur(organisation_id));

grant select, insert, update on public.inscriptions to authenticated;
create policy "membres lisent" on public.inscriptions for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "inscripteur ajoute" on public.inscriptions for insert to authenticated
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'));
create policy "inscripteur modifie" on public.inscriptions for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'))
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'gerer_inscriptions'));

grant select on public.historique_eleves to authenticated;
create policy "membres lisent" on public.historique_eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));

-- Contacts des familles (téléphones) : seulement ceux qui inscrivent ou encaissent.
create or replace function scolagrid.voit_familles(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.a_le_droit_quelque_part(org, 'gerer_inscriptions')
      or scolagrid.a_le_droit_quelque_part(org, 'encaisser')
$$;
revoke all on function scolagrid.voit_familles(uuid) from public;
grant execute on function scolagrid.voit_familles(uuid) to authenticated;

grant select, insert, update on public.contacts to authenticated;
create policy "familles : lecture" on public.contacts for select to authenticated
  using (scolagrid.voit_familles(organisation_id));
create policy "familles : ajout" on public.contacts for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'));
create policy "familles : modification" on public.contacts for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'))
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'));

grant select, insert, update, delete on public.eleves_contacts to authenticated;
create policy "familles : lecture" on public.eleves_contacts for select to authenticated
  using (scolagrid.voit_familles(organisation_id));
create policy "familles : ajout" on public.eleves_contacts for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'));
create policy "familles : modification" on public.eleves_contacts for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'))
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'));
create policy "familles : retrait" on public.eleves_contacts for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions'));

alter publication powersync add table public.eleves, public.contacts, public.eleves_contacts,
  public.inscriptions, public.historique_eleves;
