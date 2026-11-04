-- 034 : dépenses (sorties de caisse courantes).
--
-- But : rendre la clôture de caisse exacte. Une dépense est toujours une sortie
-- de CAISSE (le compte bancaire n'est pas suivi). Motif obligatoire, justificatif
-- facultatif (beaucoup d'achats se font sans reçu au marché). Bon de sortie
-- facultatif (n° du carnet de l'école).
--
-- Autorisation par SEUIL (réglage de l'école) :
--   - en dessous : la caisse enregistre seule, l'argent sort tout de suite ;
--   - au-dessus : il faut le droit « autoriser_depense » (direction). Soit la
--     personne l'a et l'argent sort ; soit c'est une DEMANDE, autorisée (ou
--     refusée) dans l'app, puis la caisse sort l'argent ; soit (si l'école
--     l'active) une autorisation donnée de VIVE VOIX, marquée « à confirmer ».
-- Les salaires, avances et remboursements n'en font pas partie (déjà suivis ailleurs).

alter table public.organisations
  add column seuil_depense_gnf bigint not null default 100000 check (seuil_depense_gnf >= 0),
  add column depense_orale boolean not null default false;

-- La direction autorise les dépenses par défaut (le fondateur a tous les droits).
create or replace function scolagrid.droits_par_defaut(fonction text) returns text[]
language sql immutable set search_path = '' as $$
  select case fonction
    when 'directeur' then array['valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
                                'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord',
                                'gerer_inscriptions', 'voir_familles', 'voir_caisse', 'voir_personnel',
                                'autoriser_depense']
    when 'directeur_etudes' then array['gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence']
    when 'surveillant' then array['faire_appel', 'justifier_absence']
    when 'enseignant' then array['saisir_notes', 'faire_appel']
    when 'secretaire' then array['gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse']
    when 'comptable' then array['consulter_tableau_bord', 'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse']
    when 'caissier' then array['encaisser', 'voir_familles', 'voir_caisse']
    else array[]::text[]
  end
$$;

create table public.depenses (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid not null,
  montant_gnf bigint not null check (montant_gnf > 0),
  date_effective date not null,
  categorie text not null check (length(trim(categorie)) between 2 and 60),
  motif text not null check (length(trim(motif)) between 3 and 300),
  beneficiaire text check (beneficiaire is null or length(trim(beneficiaire)) between 2 and 120),
  bon text check (bon is null or length(trim(bon)) between 1 and 40),         -- n° du bon de sortie papier
  statut text not null default 'demande' check (statut in ('demande', 'autorisee', 'refusee', 'sortie', 'annulee')),
  cree_par uuid references auth.users (id) on delete set null,
  autorise_par uuid references auth.users (id) on delete set null,
  autorise_le timestamptz,
  motif_refus text check (motif_refus is null or length(trim(motif_refus)) between 3 and 300),
  autorisation_orale boolean not null default false,
  autorise_oralement_par uuid,                -- fiche du membre de la direction qui a dit oui
  confirmation text check (confirmation is null or confirmation in ('attendue', 'confirmee', 'contestee')),
  confirme_par uuid references auth.users (id) on delete set null,
  confirme_le timestamptz,
  motif_contestation text check (motif_contestation is null or length(trim(motif_contestation)) between 3 and 300),
  sortie_par uuid references auth.users (id) on delete set null,   -- qui a remis l'argent (sa caisse)
  sortie_le date,
  motif_annulation text check (motif_annulation is null or length(trim(motif_annulation)) between 3 and 300),
  annule_par uuid references auth.users (id) on delete set null,
  annule_le timestamptz,
  poste_id uuid references public.postes (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id),
  foreign key (autorise_oralement_par, organisation_id) references public.personnel (id, organisation_id)
);
create index depenses_jour_idx on public.depenses (organisation_id, site_id, sortie_le);

create table public.justificatifs_depenses (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  depense_id uuid not null unique,
  type_image text not null check (type_image in ('image/jpeg', 'image/png')),
  image text not null check (length(image) between 100 and 400000),   -- base64, 300 Ko au plus
  par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (depense_id, organisation_id) references public.depenses (id, organisation_id) on delete cascade
);

do $$ declare t text; begin
  foreach t in array array['depenses', 'justificatifs_depenses'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to powersync_role', t);
    execute format('create trigger maj_updated_at before update on public.%I for each row execute function scolagrid.maj_updated_at()', t);
    execute format('create trigger organisation_immuable before update on public.%I for each row execute function scolagrid.organisation_immuable()', t);
  end loop;
end $$;

-- Le circuit d'une dépense, vérifié par le serveur.
create or replace function scolagrid.depense_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  o public.organisations;
  connecte boolean := nullif(current_setting('request.jwt.claim.sub', true), '') is not null;
  autorise boolean;
begin
  if tg_op = 'INSERT' then
    select * into o from public.organisations where id = new.organisation_id;
    new.autorise_par := null; new.autorise_le := null; new.motif_refus := null;
    new.confirme_par := null; new.confirme_le := null; new.motif_contestation := null;
    new.sortie_par := null; new.sortie_le := null;
    new.motif_annulation := null; new.annule_par := null; new.annule_le := null;
    if connecte then new.cree_par := auth.uid(); end if;
    autorise := connecte and scolagrid.a_le_droit(new.organisation_id, new.site_id, 'autoriser_depense');
    if new.montant_gnf <= o.seuil_depense_gnf or autorise or not connecte then
      -- Sous le seuil, ou enregistrée par la direction : l'argent sort tout de suite.
      new.statut := 'sortie';
      new.autorisation_orale := false; new.autorise_oralement_par := null; new.confirmation := null;
      if new.montant_gnf > o.seuil_depense_gnf and connecte then
        new.autorise_par := auth.uid(); new.autorise_le := now();
      end if;
    elsif new.autorisation_orale then
      if not o.depense_orale then
        raise exception 'L''école n''accepte pas les autorisations de vive voix pour les dépenses' using errcode = '23514';
      end if;
      if new.autorise_oralement_par is null then
        raise exception 'Indiquez qui a autorisé la dépense' using errcode = '23514';
      end if;
      -- Jamais la caisse seule : la personne qui autorise n'est pas celle qui enregistre.
      if exists (select 1 from public.personnel where id = new.autorise_oralement_par and user_id = auth.uid()) then
        raise exception 'On ne s''autorise pas soi-même de vive voix' using errcode = '23514';
      end if;
      new.statut := 'sortie';
      new.autorise_le := now();
      new.confirmation := 'attendue';
    else
      new.statut := 'demande';
      new.autorise_oralement_par := null; new.confirmation := null;
    end if;
    if new.statut = 'sortie' then
      new.sortie_par := coalesce(auth.uid(), new.cree_par);
      new.sortie_le := new.date_effective;
    end if;
    return new;
  end if;

  -- Mise à jour : seules les étapes du circuit ; le reste est figé.
  new.site_id := old.site_id; new.montant_gnf := old.montant_gnf; new.categorie := old.categorie;
  new.motif := old.motif; new.beneficiaire := old.beneficiaire; new.cree_par := old.cree_par;
  new.created_at := old.created_at; new.poste_id := old.poste_id;
  new.autorisation_orale := old.autorisation_orale; new.autorise_oralement_par := old.autorise_oralement_par;
  -- Le n° du bon peut être ajouté plus tard (bon signé après coup).

  if old.confirmation = 'attendue' and new.confirmation in ('confirmee', 'contestee') then
    if connecte and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'autoriser_depense') then
      raise exception 'Confirmer une dépense demande le droit « autoriser une dépense »' using errcode = '42501';
    end if;
    if new.confirmation = 'contestee' and new.motif_contestation is null then
      raise exception 'Une contestation doit être motivée' using errcode = '23514';
    end if;
    if connecte then new.confirme_par := auth.uid(); end if;
    new.confirme_le := now();
    if new.confirmation = 'confirmee' then new.motif_contestation := null; end if;
    new.statut := old.statut; new.date_effective := old.date_effective;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le; new.motif_refus := old.motif_refus;
    new.sortie_par := old.sortie_par; new.sortie_le := old.sortie_le;
    new.motif_annulation := old.motif_annulation; new.annule_par := old.annule_par; new.annule_le := old.annule_le;
    return new;
  end if;
  new.confirmation := old.confirmation; new.confirme_par := old.confirme_par;
  new.confirme_le := old.confirme_le; new.motif_contestation := old.motif_contestation;

  if new.statut = old.statut then
    new.date_effective := old.date_effective;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le; new.motif_refus := old.motif_refus;
    new.sortie_par := old.sortie_par; new.sortie_le := old.sortie_le;
    new.motif_annulation := old.motif_annulation; new.annule_par := old.annule_par; new.annule_le := old.annule_le;
    return new;
  end if;
  if old.statut = 'demande' and new.statut in ('autorisee', 'refusee') then
    if connecte and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'autoriser_depense') then
      raise exception 'Autoriser une dépense demande le droit « autoriser une dépense »' using errcode = '42501';
    end if;
    if new.statut = 'refusee' and new.motif_refus is null then
      raise exception 'Un refus doit être motivé' using errcode = '23514';
    end if;
    new.autorise_par := case when connecte then auth.uid() else new.autorise_par end;
    new.autorise_le := now();
    new.date_effective := old.date_effective;
    new.sortie_par := null; new.sortie_le := null;
    return new;
  end if;
  if old.statut = 'autorisee' and new.statut = 'sortie' then
    if connecte and not (scolagrid.a_le_droit(old.organisation_id, old.site_id, 'encaisser')
                         or scolagrid.a_le_droit(old.organisation_id, old.site_id, 'autoriser_depense')) then
      raise exception 'Sortir l''argent demande le droit « encaisser »' using errcode = '42501';
    end if;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le; new.motif_refus := old.motif_refus;
    if connecte then new.sortie_par := auth.uid(); end if;
    new.sortie_le := coalesce(new.sortie_le, current_date);
    new.date_effective := new.sortie_le;
    return new;
  end if;
  if new.statut = 'annulee' and old.statut in ('demande', 'autorisee', 'sortie') then
    if new.motif_annulation is null then
      raise exception 'Une annulation doit être motivée' using errcode = '23514';
    end if;
    if connecte and not (scolagrid.a_le_droit(old.organisation_id, old.site_id, 'autoriser_depense')
                         or (old.statut <> 'sortie' and old.cree_par = auth.uid())) then
      raise exception 'Annuler cette dépense demande le droit « autoriser une dépense »' using errcode = '42501';
    end if;
    -- Une sortie d'une journée déjà clôturée ne bouge plus.
    if old.statut = 'sortie' and exists (select 1 from public.clotures_caisse c
        where c.organisation_id = old.organisation_id and c.site_id = old.site_id
          and c.encaisse_par = old.sortie_par and c.jour = old.sortie_le) then
      raise exception 'Cette journée de caisse est clôturée : la dépense ne peut plus être annulée' using errcode = '23514';
    end if;
    if connecte then new.annule_par := auth.uid(); end if;
    new.annule_le := now();
    new.date_effective := old.date_effective;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le; new.motif_refus := old.motif_refus;
    new.sortie_par := old.sortie_par; new.sortie_le := old.sortie_le;
    return new;
  end if;
  raise exception 'Étape de dépense impossible : % → %', old.statut, new.statut using errcode = '23514';
end $$;
create trigger depense_controle before insert or update on public.depenses
  for each row execute function scolagrid.depense_controle();
revoke all on function scolagrid.depense_controle() from public;

-- La clôture déduit aussi les dépenses sorties de la caisse ce jour-là.
create or replace function scolagrid.cloture_calculee() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  sorties bigint;
  avant record;
begin
  if tg_op = 'UPDATE' then
    raise exception 'Une clôture de caisse ne se modifie pas' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext(new.organisation_id::text || new.site_id::text || new.encaisse_par::text || new.jour::text));
  select coalesce(sum(total_gnf) filter (where mode = 'especes'), 0),
         count(*),
         coalesce(sum(total_gnf) filter (where mode <> 'especes'), 0)
    into new.attendu_especes, new.nb_recus, new.total_autres_modes
  from public.encaissements
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and date_effective = new.jour and statut = 'valide';
  select coalesce(sum(montant_gnf), 0) into sorties from public.remboursements
  where organisation_id = new.organisation_id and site_id = new.site_id and verse_par = new.encaisse_par
    and verse_le = new.jour and statut = 'verse' and mode = 'especes';
  sorties := sorties + (select coalesce(sum(montant_gnf), 0) from public.depenses
    where organisation_id = new.organisation_id and site_id = new.site_id and sortie_par = new.encaisse_par
      and sortie_le = new.jour and statut = 'sortie');
  select count(*) as n, coalesce(sum(attendu_especes), 0) as attendu, coalesce(sum(nb_recus), 0) as recus,
         coalesce(sum(total_autres_modes), 0) as autres
    into avant
  from public.clotures_caisse
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and jour = new.jour;
  new.rang := avant.n + 1;
  new.attendu_especes := new.attendu_especes - sorties - avant.attendu;
  new.nb_recus := new.nb_recus - avant.recus;
  new.total_autres_modes := new.total_autres_modes - avant.autres;
  if avant.n > 0 and new.nb_recus <= 0 and new.attendu_especes = 0 then
    raise exception 'Rien de nouveau à clôturer depuis la dernière clôture' using errcode = '23505';
  end if;
  new.ecart := new.compte_especes - new.attendu_especes;
  if new.ecart <> 0 and new.justification is null then
    raise exception 'Un écart de caisse doit être justifié' using errcode = '23514';
  end if;
  return new;
end $$;

-- Règles d'accès : ceux qui voient la caisse lisent ; la caisse et la direction écrivent
-- (le circuit est contrôlé par le déclencheur).
create or replace function scolagrid.lit_caisse(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rattachements
                 where organisation_id = org and user_id = auth.uid() and actif and lit_caisse)
$$;
revoke all on function scolagrid.lit_caisse(uuid) from public;
grant execute on function scolagrid.lit_caisse(uuid) to authenticated;

grant select, insert, update on public.depenses to authenticated;
create policy "caisse : lecture" on public.depenses for select to authenticated
  using (scolagrid.lit_caisse(organisation_id));
create policy "caisse et direction : saisie" on public.depenses for insert to authenticated
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'encaisser')
              or scolagrid.a_le_droit(organisation_id, site_id, 'autoriser_depense'));
create policy "circuit de la dépense" on public.depenses for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'encaisser')
         or scolagrid.a_le_droit(organisation_id, site_id, 'autoriser_depense'))
  with check (true);

grant select, insert on public.justificatifs_depenses to authenticated;
create policy "caisse : lecture" on public.justificatifs_depenses for select to authenticated
  using (scolagrid.lit_caisse(organisation_id));
create policy "caisse et direction : ajout" on public.justificatifs_depenses for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'encaisser')
              or scolagrid.a_le_droit_quelque_part(organisation_id, 'autoriser_depense'));

alter publication powersync add table public.depenses, public.justificatifs_depenses;
