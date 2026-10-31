-- 004 : personnel, fonctions, droits et invitations (étape 3 de l'onboarding).
--
-- Fiche ≠ compte : tout le personnel a une fiche (le gardien aussi) ; seules
-- les personnes qui utilisent l'app y relient un compte, par une invitation.
-- Fonctions cumulables : une fiche peut avoir plusieurs fonctions, chacune sur
-- un site ou sur tout le groupe. Chaque fonction donne des droits par défaut ;
-- le fondateur peut accorder ou retirer un droit précis à une personne.
--
-- Les rattachements (qui donnent l'accès aux données) sont désormais calculés
-- par le serveur à partir des fonctions des fiches reliées à un compte.
-- On ne supprime ni fiche ni fonction : on les désactive (historique).

-- Fonctions reconnues ----------------------------------------------------------

alter table public.rattachements drop constraint rattachements_role_check;
alter table public.rattachements add constraint rattachements_role_check check (role in (
  'fondateur', 'directeur', 'directeur_etudes', 'surveillant', 'secretaire',
  'comptable', 'caissier', 'enseignant', 'autre'));

-- Droits par défaut de chaque fonction. Le fondateur a tous les droits.
-- L'accès aux salaires (préparer, valider, verser la paie) n'est jamais automatique.
create or replace function scolagrid.droits_par_defaut(fonction text) returns text[]
language sql immutable set search_path = '' as $$
  select case fonction
    when 'directeur' then array['valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
                                'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord']
    when 'directeur_etudes' then array['gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence']
    when 'surveillant' then array['faire_appel', 'justifier_absence']
    when 'enseignant' then array['saisir_notes', 'faire_appel']
    when 'comptable' then array['consulter_tableau_bord']
    else array[]::text[]
  end
$$;

-- Tables -------------------------------------------------------------------------

create table public.personnel (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid,                     -- site principal ; vide = personnel du groupe
  nom_complet text not null check (length(trim(nom_complet)) between 2 and 120),
  telephone text check (telephone is null or telephone ~ '^\+?[0-9 ]{8,20}$'),
  user_id uuid references auth.users (id) on delete set null,   -- vide = pas de compte
  statut text not null default 'actif' check (statut in ('actif', 'sorti')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id),
  unique (organisation_id, user_id),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade
);
create index personnel_user_idx on public.personnel (user_id);
create index personnel_site_idx on public.personnel (site_id);

create table public.affectations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null,
  site_id uuid,                     -- vide = tous les sites
  fonction text not null check (fonction in (
    'fondateur', 'directeur', 'directeur_etudes', 'surveillant', 'secretaire',
    'comptable', 'caissier', 'enseignant', 'autre')),
  libelle text check (libelle is null or length(trim(libelle)) between 2 and 60),  -- « Gardien »
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (personnel_id, site_id, fonction),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade,
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade
);
create index affectations_site_idx on public.affectations (site_id);

-- Exceptions aux droits par défaut : accorde = true ajoute, false retire.
create table public.droits_personnel (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null,
  site_id uuid,                     -- vide = tous les sites
  droit text not null check (droit in (
    'valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps', 'planifier_evaluations',
    'saisir_notes', 'faire_appel', 'justifier_absence', 'preparer_paie', 'valider_paie',
    'verser_paie', 'consulter_tableau_bord', 'autoriser_depense')),
  accorde boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (personnel_id, site_id, droit),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade,
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade
);

-- Invitations : un code à usage unique, valable 7 jours, qui relie un compte à une fiche.
-- Elles se créent et s'utilisent en ligne, par les fonctions plus bas.
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null,
  code text not null unique check (code ~ '^[A-Z0-9]{8}$'),
  expire_le timestamptz not null,
  acceptee_le timestamptz,
  acceptee_par uuid references auth.users (id) on delete set null,
  annulee_le timestamptz,
  cree_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade
);
create index invitations_personnel_idx on public.invitations (personnel_id);

-- Tentatives de code, pour bloquer les essais au hasard.
create table scolagrid.essais_code (
  user_id uuid not null,
  essaye_le timestamptz not null default now()
);
create index essais_code_idx on scolagrid.essais_code (user_id, essaye_le);

do $$
declare t text;
begin
  foreach t in array array['personnel', 'affectations', 'droits_personnel', 'invitations'] loop
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

-- Une fonction ou un droit ne passe pas d'une fiche à une autre.
create or replace function scolagrid.personnel_immuable() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.personnel_id is distinct from old.personnel_id then
    raise exception 'personnel_id ne peut pas être modifié' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger personnel_immuable before update on public.affectations
  for each row execute function scolagrid.personnel_immuable();
create trigger personnel_immuable before update on public.droits_personnel
  for each row execute function scolagrid.personnel_immuable();

-- Le compte relié à une fiche ne se choisit pas depuis l'app : seulement par invitation.
create or replace function scolagrid.personnel_protege() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.user_id := null;
    else
      new.user_id := old.user_id;
    end if;
  end if;
  return new;
end $$;
create trigger personnel_protege before insert or update on public.personnel
  for each row execute function scolagrid.personnel_protege();

-- Reprise de l'existant : une fiche et des fonctions pour chaque compte déjà rattaché.
insert into public.personnel (organisation_id, nom_complet, telephone, user_id)
select distinct on (r.organisation_id, r.user_id)
       r.organisation_id, coalesce(p.nom_complet, 'Sans nom'), p.telephone, r.user_id
from public.rattachements r
left join public.personnes p on p.id = r.user_id;

insert into public.affectations (organisation_id, personnel_id, site_id, fonction, actif)
select r.organisation_id, f.id, r.site_id, r.role, r.actif
from public.rattachements r
join public.personnel f on f.organisation_id = r.organisation_id and f.user_id = r.user_id;

-- Calcul des accès ------------------------------------------------------------------

-- Recalcule les rattachements d'une fiche reliée à un compte, à partir de ses fonctions.
create or replace function scolagrid.recalculer_acces(fiche uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org uuid; compte uuid; en_poste boolean;
begin
  select organisation_id, user_id, statut = 'actif' into org, compte, en_poste
  from public.personnel where id = fiche;
  if compte is null then return; end if;

  update public.rattachements r
  set actif = en_poste and exists (
    select 1 from public.affectations a
    where a.personnel_id = fiche and a.actif and a.fonction = r.role and a.site_id is not distinct from r.site_id)
  where r.organisation_id = org and r.user_id = compte
    and r.actif is distinct from (en_poste and exists (
      select 1 from public.affectations a
      where a.personnel_id = fiche and a.actif and a.fonction = r.role and a.site_id is not distinct from r.site_id));

  insert into public.rattachements (organisation_id, site_id, user_id, role)
  select org, a.site_id, compte, a.fonction
  from public.affectations a
  where en_poste and a.personnel_id = fiche and a.actif
    and not exists (select 1 from public.rattachements r
                    where r.organisation_id = org and r.user_id = compte
                      and r.role = a.fonction and r.site_id is not distinct from a.site_id);
end $$;

-- Un groupe garde toujours au moins un fondateur qui peut se connecter.
create or replace function scolagrid.verifier_fondateur(org uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.rattachements
                 where organisation_id = org and role = 'fondateur' and actif) then
    raise exception 'Le groupe doit garder au moins un fondateur' using errcode = '23514';
  end if;
end $$;

create or replace function scolagrid.apres_affectation() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform scolagrid.recalculer_acces(new.personnel_id);
  if tg_op = 'UPDATE' and old.fonction = 'fondateur' then
    perform scolagrid.verifier_fondateur(new.organisation_id);
  end if;
  return null;
end $$;
create trigger apres_affectation after insert or update on public.affectations
  for each row execute function scolagrid.apres_affectation();

create or replace function scolagrid.apres_personnel() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.user_id is not null and old.user_id is distinct from new.user_id then
    update public.rattachements set actif = false
    where organisation_id = new.organisation_id and user_id = old.user_id and actif;
  end if;
  perform scolagrid.recalculer_acces(new.id);
  perform scolagrid.verifier_fondateur(new.organisation_id);
  return null;
end $$;
create trigger apres_personnel after update of user_id, statut on public.personnel
  for each row execute function scolagrid.apres_personnel();

revoke all on function scolagrid.recalculer_acces(uuid), scolagrid.verifier_fondateur(uuid),
  scolagrid.apres_affectation(), scolagrid.apres_personnel() from public;

-- Fonctions d'aide aux règles ---------------------------------------------------------

-- Gère un périmètre : un site (son directeur ou le fondateur), ou tout le groupe (le fondateur).
create or replace function scolagrid.gere_perimetre(org uuid, site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when site is null then scolagrid.est_fondateur(org) else scolagrid.gere_site(org, site) end
$$;

-- Fiches que je gère : celles de mon périmètre, et celles qui ont une fonction sur un site que je dirige.
create or replace function scolagrid.personnel_que_je_gere() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select p.id from public.personnel p
  where p.organisation_id in (select scolagrid.mes_organisations())
    and scolagrid.gere_perimetre(p.organisation_id, p.site_id)
  union
  select a.personnel_id from public.affectations a
  where a.organisation_id in (select scolagrid.mes_organisations())
    and a.site_id is not null and scolagrid.gere_site(a.organisation_id, a.site_id)
$$;

-- Une fiche de direction (fondateur ou directeur) ne se modifie que par le fondateur.
create or replace function scolagrid.fiche_de_direction(fiche uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.affectations
                 where personnel_id = fiche and actif and fonction in ('fondateur', 'directeur'))
$$;

-- Fiches que je vois : celles que je gère, et la mienne.
create or replace function scolagrid.personnel_visible() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select scolagrid.personnel_que_je_gere()
  union
  select id from public.personnel where user_id = auth.uid()
$$;

-- Ai-je ce droit, sur ce site (ou sur tout le groupe si site est vide) ?
-- Fondateur : toujours. Sinon : droit par défaut d'une de mes fonctions, ou accordé,
-- et pas retiré.
create or replace function scolagrid.a_le_droit(org uuid, site uuid, quel_droit text) returns boolean
language sql stable security definer set search_path = '' as $$
  with moi as (
    select id from public.personnel
    where organisation_id = org and user_id = auth.uid() and statut = 'actif'
  )
  select scolagrid.est_fondateur(org) or (
    (exists (select 1 from public.affectations a
             where a.personnel_id in (select id from moi) and a.actif
               and (a.site_id is null or a.site_id = site)
               and quel_droit = any (scolagrid.droits_par_defaut(a.fonction)))
     or exists (select 1 from public.droits_personnel d
                where d.personnel_id in (select id from moi) and d.accorde
                  and (d.site_id is null or d.site_id = site) and d.droit = quel_droit))
    and not exists (select 1 from public.droits_personnel d
                    where d.personnel_id in (select id from moi) and not d.accorde
                      and (d.site_id is null or d.site_id = site) and d.droit = quel_droit))
$$;

revoke all on function scolagrid.gere_perimetre(uuid, uuid), scolagrid.personnel_que_je_gere(),
  scolagrid.personnel_visible(), scolagrid.a_le_droit(uuid, uuid, text), scolagrid.fiche_de_direction(uuid) from public;
grant execute on function scolagrid.gere_perimetre(uuid, uuid), scolagrid.personnel_que_je_gere(),
  scolagrid.fiche_de_direction(uuid),
  scolagrid.personnel_visible(), scolagrid.a_le_droit(uuid, uuid, text), scolagrid.droits_par_defaut(text)
  to authenticated;

-- Règles d'accès ------------------------------------------------------------------------

grant select, insert, update on public.personnel to authenticated;
-- Les conditions sur la ligne elle-même passent en premier : une fiche qu'on vient
-- d'ajouter n'est pas encore visible des fonctions d'aide.
create policy "gestionnaires et intéressé lisent" on public.personnel for select to authenticated
  using (scolagrid.gere_perimetre(organisation_id, site_id) or user_id = auth.uid()
         or id in (select scolagrid.personnel_que_je_gere()));
create policy "gestionnaire ajoute" on public.personnel for insert to authenticated
  with check (scolagrid.gere_perimetre(organisation_id, site_id));
create policy "gestionnaire modifie" on public.personnel for update to authenticated
  using (id in (select scolagrid.personnel_que_je_gere())
         and (scolagrid.est_fondateur(organisation_id) or not scolagrid.fiche_de_direction(id)))
  with check (scolagrid.gere_perimetre(organisation_id, site_id) or scolagrid.est_fondateur(organisation_id));

-- Fonctions : le gestionnaire du site les attribue ; seules les fonctions
-- de direction (fondateur, directeur) sont réservées au fondateur.
grant select, insert, update on public.affectations to authenticated;
create policy "gestionnaires et intéressé lisent" on public.affectations for select to authenticated
  using (scolagrid.gere_perimetre(organisation_id, site_id) or personnel_id in (select scolagrid.personnel_visible()));
create policy "gestionnaire attribue" on public.affectations for insert to authenticated
  with check (scolagrid.gere_perimetre(organisation_id, site_id)
              and (fonction not in ('fondateur', 'directeur') or scolagrid.est_fondateur(organisation_id)));
create policy "gestionnaire modifie" on public.affectations for update to authenticated
  using (scolagrid.gere_perimetre(organisation_id, site_id)
         and (fonction not in ('fondateur', 'directeur') or scolagrid.est_fondateur(organisation_id)))
  with check (scolagrid.gere_perimetre(organisation_id, site_id)
              and (fonction not in ('fondateur', 'directeur') or scolagrid.est_fondateur(organisation_id)));

-- Droits particuliers : le fondateur seul.
grant select, insert, update, delete on public.droits_personnel to authenticated;
create policy "gestionnaires et intéressé lisent" on public.droits_personnel for select to authenticated
  using (personnel_id in (select scolagrid.personnel_visible()));
create policy "fondateur ajoute" on public.droits_personnel for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur modifie" on public.droits_personnel for update to authenticated
  using (scolagrid.est_fondateur(organisation_id)) with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur supprime" on public.droits_personnel for delete to authenticated
  using (scolagrid.est_fondateur(organisation_id));

-- Invitations : lues par ceux qui gèrent la fiche ; écrites par les fonctions ci-dessous.
grant select on public.invitations to authenticated;
create policy "gestionnaires lisent" on public.invitations for select to authenticated
  using (personnel_id in (select scolagrid.personnel_que_je_gere()));

-- Étape 1 : la création d'espace crée aussi la fiche du fondateur ---------------------------

create or replace function public.creer_espace_ecole(
  nom_groupe text, ville text, nom_site text, nom_complet text
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

  insert into public.personnel (organisation_id, nom_complet, telephone, user_id)
  values (org, trim(nom_complet), tel, moi)
  returning id into fiche;

  -- Le rattachement « fondateur » est créé par le calcul des accès.
  insert into public.affectations (organisation_id, personnel_id, fonction)
  values (org, fiche, 'fondateur');

  return org;
end $$;

-- Étape 3 : inviter une personne ---------------------------------------------------------

-- Ne garde que les chiffres d'un numéro guinéen, avec l'indicatif 224.
create or replace function scolagrid.numero_normalise(numero text) returns text
language sql immutable set search_path = '' as $$
  select case when length(n) = 9 then '224' || n else n end
  from (select regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as n) x
$$;

-- Crée un code d'invitation pour une fiche sans compte. Annule les codes précédents.
create or replace function public.inviter_personnel(fiche uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  p public.personnel;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32 signes, sans O/0 ni I/1
  octets bytea;
  nouveau text;
begin
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  select * into p from public.personnel where id = fiche for update;
  if not found or p.id not in (select scolagrid.personnel_que_je_gere()) then
    raise exception 'Fiche introuvable' using errcode = '42501';
  end if;
  if p.statut <> 'actif' then
    raise exception 'Cette personne ne fait plus partie du personnel' using errcode = '22023';
  end if;
  if p.user_id is not null then
    raise exception 'Cette personne a déjà un compte' using errcode = '22023';
  end if;
  if not exists (select 1 from public.affectations where personnel_id = fiche and actif) then
    raise exception 'Donnez d''abord une fonction à cette personne' using errcode = '22023';
  end if;

  update public.invitations set annulee_le = now()
  where personnel_id = fiche and acceptee_le is null and annulee_le is null;

  loop
    -- Octets aléatoires du générateur sûr de Postgres (8 octets entièrement aléatoires).
    octets := substring(uuid_send(gen_random_uuid()) from 1 for 6) || substring(uuid_send(gen_random_uuid()) from 11 for 2);
    nouveau := '';
    for i in 0..7 loop
      nouveau := nouveau || substr(alphabet, get_byte(octets, i) % 32 + 1, 1);
    end loop;
    exit when not exists (select 1 from public.invitations where code = nouveau);
  end loop;

  insert into public.invitations (organisation_id, personnel_id, code, expire_le, cree_par)
  values (p.organisation_id, fiche, nouveau, now() + interval '7 days', moi);
  return nouveau;
end $$;

-- Utilise un code : relie le compte connecté à la fiche. Renvoie l'organisation,
-- ou rien si le code est faux ou expiré. Au-delà de 10 essais par heure : refusé.
create or replace function public.accepter_invitation(code_saisi text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  c text := upper(regexp_replace(coalesce(code_saisi, ''), '[^A-Za-z0-9]', '', 'g'));
  inv public.invitations;
  p public.personnel;
  tel text;
begin
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  if (select count(*) from scolagrid.essais_code where user_id = moi and essaye_le > now() - interval '1 hour') >= 10 then
    raise exception 'Trop d''essais. Réessayez dans une heure.' using errcode = '54000';
  end if;

  select * into inv from public.invitations i
  where i.code = c and i.acceptee_le is null and i.annulee_le is null and i.expire_le > now()
  for update;
  if not found then
    insert into scolagrid.essais_code (user_id) values (moi);
    return null;
  end if;

  select * into p from public.personnel where id = inv.personnel_id for update;
  if p.user_id is not null or p.statut <> 'actif' then
    raise exception 'Cette invitation n''est plus valable' using errcode = '22023';
  end if;
  if exists (select 1 from public.personnel where organisation_id = p.organisation_id and user_id = moi) then
    raise exception 'Votre compte est déjà relié à une fiche de cette école' using errcode = '22023';
  end if;
  select phone into tel from auth.users where id = moi;
  if p.telephone is not null and scolagrid.numero_normalise(p.telephone) <> scolagrid.numero_normalise(tel) then
    raise exception 'Ce code est destiné à un autre numéro de téléphone' using errcode = '42501';
  end if;

  insert into public.personnes (id, nom_complet, telephone)
  values (moi, p.nom_complet, tel)
  on conflict (id) do nothing;

  update public.personnel set user_id = moi, telephone = coalesce(telephone, tel) where id = p.id;
  update public.invitations set acceptee_le = now(), acceptee_par = moi where id = inv.id;
  return p.organisation_id;
end $$;

revoke all on function public.inviter_personnel(uuid), public.accepter_invitation(text) from public, anon;
grant execute on function public.inviter_personnel(uuid), public.accepter_invitation(text) to authenticated;
revoke all on function scolagrid.numero_normalise(text) from public;

-- Synchronisation : les fiches, fonctions et droits (pas les invitations, qui restent en ligne).
alter publication powersync add table public.personnel, public.affectations, public.droits_personnel;
