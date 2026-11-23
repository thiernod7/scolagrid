-- 046 : fiche du personnel complétée, statuts, et paie (mensuelle ou à l'heure).
--
-- Fiche : état civil, contact, embauche, contrat, diplôme ; statuts actif, en
-- congé, suspendu, parti (avec la date et le motif du départ, à part). En congé
-- ou suspendu, l'accès à l'app est coupé comme au départ ; les enseignements
-- d'un congé ne sont pas terminés (un remplaçant s'ajoute par-dessus).
--
-- Paie (confidentielle : seuls ceux qui préparent, valident ou versent la paie
-- voient les montants) :
--  - rémunération par personne : au mois (salaire fixe), à l'heure (taux par
--    cycle × heures), ou les deux ; une grille de l'école propose les taux ;
--  - chaque enseignement porte ses heures par semaine (les heures prévues du
--    mois = heures × 4 ; la direction note les heures réellement faites) ;
--  - avances : versées (en espèces : une dépense sort de la caisse), retenues
--    sur un ou plusieurs mois ;
--  - paie du mois : préparée (lignes calculées par l'app), validée (figée),
--    versée personne par personne (en espèces : une dépense sort de la caisse
--    de celui qui verse ; sinon Orange Money ou virement, avec sa référence).

-- Fiche ------------------------------------------------------------------------
alter table public.personnel
  add column date_naissance date,
  add column lieu_naissance text check (lieu_naissance is null or length(trim(lieu_naissance)) between 2 and 80),
  add column sexe text check (sexe is null or sexe in ('M', 'F')),
  add column nationalite text check (nationalite is null or length(trim(nationalite)) between 2 and 60),
  add column piece_identite text check (piece_identite is null or length(trim(piece_identite)) between 2 and 60),
  add column telephone2 text check (telephone2 is null or telephone2 ~ '^\+?[0-9 ]{8,20}$'),
  add column adresse text check (adresse is null or length(trim(adresse)) between 2 and 160),
  add column contact_urgence text check (contact_urgence is null or length(trim(contact_urgence)) between 2 and 160),
  add column date_embauche date,
  add column contrat text check (contrat is null or contrat in ('permanent', 'vacataire', 'stagiaire', 'autre')),
  add column diplome text check (diplome is null or length(trim(diplome)) between 2 and 120),
  add column statut_depuis date,
  add column statut_jusqu_au date,
  add column motif_depart text check (motif_depart is null or motif_depart in
    ('demission', 'fin_contrat', 'licenciement', 'retraite', 'deces', 'autre'));
alter table public.personnel drop constraint personnel_statut_check;
alter table public.personnel add constraint personnel_statut_check check (statut in ('actif', 'conge', 'suspendu', 'sorti'));

-- Heures par semaine de chaque enseignement (base de la paie à l'heure).
alter table public.enseignements
  add column heures_semaine numeric(4, 1) check (heures_semaine is null or heures_semaine between 0.5 and 40);

-- Qui voit et touche à la paie ---------------------------------------------------
create or replace function scolagrid.gere_paie(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.a_le_droit_quelque_part(org, 'preparer_paie')
      or scolagrid.a_le_droit_quelque_part(org, 'valider_paie')
      or scolagrid.a_le_droit_quelque_part(org, 'verser_paie')
$$;
revoke all on function scolagrid.gere_paie(uuid) from public;
grant execute on function scolagrid.gere_paie(uuid) to authenticated;

-- La synchronisation de la paie : un drapeau sur le rattachement, comme les autres lectures.
alter table public.rattachements add column lit_paie boolean not null default false;
create or replace function scolagrid.recalculer_lectures(fiche uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare org uuid; compte uuid;
begin
  select organisation_id, user_id into org, compte from public.personnel where id = fiche;
  if compte is null then return; end if;
  update public.rattachements r set
    lit_familles = x.familles, lit_caisse = x.caisse, lit_personnel = x.personnel, lit_notes = x.notes, lit_paie = x.paie,
    updated_at = now()
  from (
    select r2.id,
           scolagrid.rattachement_a(r2, fiche, 'voir_familles') as familles,
           scolagrid.rattachement_a(r2, fiche, 'voir_caisse') or scolagrid.rattachement_a(r2, fiche, 'consulter_tableau_bord') as caisse,
           scolagrid.rattachement_a(r2, fiche, 'voir_personnel') as personnel,
           scolagrid.rattachement_a(r2, fiche, 'planifier_evaluations')
             or scolagrid.rattachement_a(r2, fiche, 'consulter_tableau_bord')
             or scolagrid.rattachement_a(r2, fiche, 'gerer_inscriptions') as notes,
           scolagrid.rattachement_a(r2, fiche, 'preparer_paie') or scolagrid.rattachement_a(r2, fiche, 'valider_paie')
             or scolagrid.rattachement_a(r2, fiche, 'verser_paie') as paie
    from public.rattachements r2 where r2.organisation_id = org and r2.user_id = compte
  ) x
  where r.id = x.id
    and (r.lit_familles, r.lit_caisse, r.lit_personnel, r.lit_notes, r.lit_paie)
        is distinct from (x.familles, x.caisse, x.personnel, x.notes, x.paie);
end $$;
revoke all on function scolagrid.recalculer_lectures(uuid) from public;
do $$ declare f record; begin
  for f in select id from public.personnel where user_id is not null loop
    perform scolagrid.recalculer_lectures(f.id);
  end loop;
end $$;

-- Rémunération -----------------------------------------------------------------
create table public.remunerations (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null unique,
  mode text not null check (mode in ('mensuel', 'horaire', 'mixte')),
  salaire_mensuel_gnf bigint check (salaire_mensuel_gnf is null or salaire_mensuel_gnf between 0 and 1000000000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade
);

-- Taux horaire d'une personne, par cycle (collège, lycée…).
create table public.taux_horaires (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null,
  cycle text not null check (length(trim(cycle)) between 2 and 40),
  taux_gnf bigint not null check (taux_gnf between 0 and 100000000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (personnel_id, cycle),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade
);

-- La grille de l'école : le taux proposé par cycle.
create table public.grille_taux (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  cycle text not null check (length(trim(cycle)) between 2 and 40),
  taux_gnf bigint not null check (taux_gnf between 0 and 100000000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, cycle)
);

-- Avances ----------------------------------------------------------------------
create table public.avances (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  personnel_id uuid not null,
  montant_gnf bigint not null check (montant_gnf between 1 and 1000000000),
  date_avance date not null default current_date,
  mensualites integer not null default 1 check (mensualites between 1 and 12),
  mode text not null default 'especes' check (mode in ('especes', 'orange_money', 'virement')),
  reference text check (reference is null or length(trim(reference)) between 1 and 60),
  motif text check (motif is null or length(trim(motif)) between 2 and 200),
  depense_id uuid references public.depenses (id) on delete set null,
  cree_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade
);
create index avances_personnel_idx on public.avances (personnel_id);

-- Paie du mois -----------------------------------------------------------------
create table public.paies (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  mois date not null check (extract(day from mois) = 1),
  statut text not null default 'preparation' check (statut in ('preparation', 'validee')),
  preparee_par uuid references auth.users (id) on delete set null,
  validee_par uuid references auth.users (id) on delete set null,
  validee_le timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, mois)
);

create table public.lignes_paie (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  paie_id uuid not null references public.paies (id) on delete cascade,
  personnel_id uuid not null,
  mode text not null check (mode in ('mensuel', 'horaire', 'mixte')),
  salaire_gnf bigint not null default 0 check (salaire_gnf >= 0),
  heures_gnf bigint not null default 0 check (heures_gnf >= 0),
  detail jsonb,                               -- les lignes d'heures : classe, matière, prévues, faites, taux, montant, motif
  primes_gnf bigint not null default 0 check (primes_gnf >= 0),
  retenues_gnf bigint not null default 0 check (retenues_gnf >= 0),
  retenue_avance_gnf bigint not null default 0 check (retenue_avance_gnf >= 0),
  net_gnf bigint not null check (net_gnf >= 0),
  notes text check (notes is null or length(notes) <= 500),
  versement_mode text check (versement_mode is null or versement_mode in ('especes', 'orange_money', 'virement')),
  versement_reference text check (versement_reference is null or length(trim(versement_reference)) between 1 and 60),
  versee_le date,
  versee_par uuid references auth.users (id) on delete set null,
  depense_id uuid references public.depenses (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (paie_id, personnel_id),
  check (net_gnf = salaire_gnf + heures_gnf + primes_gnf - retenues_gnf - retenue_avance_gnf),
  foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id) on delete cascade
);

do $$ declare t text; begin
  foreach t in array array['remunerations', 'taux_horaires', 'grille_taux', 'avances', 'paies', 'lignes_paie'] loop
    execute format('alter table public.%I owner to postgres', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy "paie : lecture" on public.%I for select to authenticated using (scolagrid.gere_paie(organisation_id))', t);
  end loop;
end $$;

-- Réglages de rémunération : qui prépare ou valide la paie.
do $$ declare t text; begin
  foreach t in array array['remunerations', 'taux_horaires', 'grille_taux'] loop
    execute format($p$create policy "paie : réglage" on public.%I for insert to authenticated
      with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie')
                  or scolagrid.a_le_droit_quelque_part(organisation_id, 'valider_paie'))$p$, t);
    execute format($p$create policy "paie : réglage (modif)" on public.%I for update to authenticated
      using (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie')
             or scolagrid.a_le_droit_quelque_part(organisation_id, 'valider_paie')) with check (true)$p$, t);
    execute format($p$create policy "paie : réglage (retrait)" on public.%I for delete to authenticated
      using (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie')
             or scolagrid.a_le_droit_quelque_part(organisation_id, 'valider_paie'))$p$, t);
  end loop;
end $$;

-- Une avance : qui verse ou valide la paie. Elle ne se modifie pas (on l'annule et on la refait).
create policy "paie : avance" on public.avances for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'verser_paie')
              or scolagrid.a_le_droit_quelque_part(organisation_id, 'valider_paie'));
create policy "paie : avance (modif)" on public.avances for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'valider_paie')) with check (true);

-- La paie du mois : préparée par preparer_paie ; validée par valider_paie (contrôlé plus bas).
create policy "paie : préparation" on public.paies for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie'));
create policy "paie : préparation (modif)" on public.paies for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie')
         or scolagrid.a_le_droit_quelque_part(organisation_id, 'valider_paie')) with check (true);
create policy "paie : lignes" on public.lignes_paie for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie'));
create policy "paie : lignes (modif)" on public.lignes_paie for update to authenticated
  using (scolagrid.gere_paie(organisation_id)) with check (true);
create policy "paie : lignes (retrait)" on public.lignes_paie for delete to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'preparer_paie'));

-- Les étapes de la paie, contrôlées ici quel que soit l'appareil.
create or replace function scolagrid.paie_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.statut is distinct from old.statut then
    if auth.uid() is not null and not scolagrid.a_le_droit_quelque_part(new.organisation_id, 'valider_paie') then
      raise exception 'Seul qui valide la paie la valide ou la rouvre' using errcode = '42501';
    end if;
    if new.statut = 'preparation' and exists (select 1 from public.lignes_paie where paie_id = new.id and versee_le is not null) then
      raise exception 'Des salaires sont déjà versés : la paie ne se rouvre plus' using errcode = '23514';
    end if;
    if new.statut = 'validee' then
      new.validee_par := auth.uid(); new.validee_le := now();
    else
      new.validee_par := null; new.validee_le := null;
    end if;
  end if;
  if tg_op = 'INSERT' then new.preparee_par := auth.uid(); end if;
  new.updated_at := now();
  return new;
end $$;
create trigger paie_controle before insert or update on public.paies
  for each row execute function scolagrid.paie_controle();

-- La dépense qui sort de la caisse (salaire ou avance en espèces) : enregistrée
-- par le serveur, directement « sortie » de la caisse de celui qui verse.
create or replace function scolagrid.depense_paie() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('scolagrid.paie', true) = 'oui' then
    new.statut := 'sortie';
    new.autorisation_orale := false; new.autorise_oralement_par := null; new.confirmation := null;
    new.autorise_par := auth.uid(); new.autorise_le := now();
    new.sortie_par := auth.uid(); new.sortie_le := new.date_effective;
  end if;
  return new;
end $$;
-- Après depense_controle, avant depense_z_dates (ordre alphabétique).
create trigger depense_paie before insert on public.depenses
  for each row execute function scolagrid.depense_paie();

create or replace function scolagrid.depense_de_paie(org uuid, fiche uuid, montant bigint, categorie text, motif text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare site uuid; nom text; id_depense uuid;
begin
  select coalesce((select r.site_id from public.rattachements r
                   where r.organisation_id = org and r.user_id = auth.uid() and r.actif and r.site_id is not null limit 1),
                  p.site_id,
                  (select s.id from public.sites s where s.organisation_id = org order by s.created_at limit 1)),
         p.nom_complet
    into site, nom from public.personnel p where p.id = fiche;
  perform set_config('scolagrid.paie', 'oui', true);
  insert into public.depenses (organisation_id, site_id, montant_gnf, date_effective, categorie, motif, beneficiaire)
  values (org, site, montant, current_date, categorie, motif, nom)
  returning id into id_depense;
  perform set_config('scolagrid.paie', '', true);
  return id_depense;
end $$;
revoke all on function scolagrid.depense_de_paie(uuid, uuid, bigint, text, text) from public;

create or replace function scolagrid.ligne_paie_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.paies; seulement_versement boolean; mois text;
begin
  select * into p from public.paies where id = coalesce(new.paie_id, old.paie_id);
  if tg_op = 'DELETE' then
    if p.statut <> 'preparation' then
      raise exception 'Paie validée : ses lignes sont figées' using errcode = '23514';
    end if;
    return old;
  end if;
  seulement_versement := tg_op = 'UPDATE'
    and (to_jsonb(new) - 'versement_mode' - 'versement_reference' - 'versee_le' - 'versee_par' - 'depense_id' - 'updated_at')
      = (to_jsonb(old) - 'versement_mode' - 'versement_reference' - 'versee_le' - 'versee_par' - 'depense_id' - 'updated_at');
  if not seulement_versement then
    if p.statut <> 'preparation' then
      raise exception 'Paie validée : ses montants sont figés' using errcode = '23514';
    end if;
    if auth.uid() is not null and not scolagrid.a_le_droit_quelque_part(new.organisation_id, 'preparer_paie') then
      raise exception 'Seul qui prépare la paie la modifie' using errcode = '42501';
    end if;
    if tg_op = 'INSERT' and (new.versee_le is not null or new.versement_mode is not null) then
      raise exception 'Une ligne de paie se verse après la validation' using errcode = '23514';
    end if;
  else
    -- Le versement : la paie validée, par qui verse, une seule fois.
    if old.versee_le is not null then
      raise exception 'Salaire déjà versé' using errcode = '23514';
    end if;
    if new.versee_le is null then return new; end if;
    if p.statut <> 'validee' then
      raise exception 'La paie doit être validée avant le versement' using errcode = '23514';
    end if;
    if auth.uid() is not null and not scolagrid.a_le_droit_quelque_part(new.organisation_id, 'verser_paie') then
      raise exception 'Seul qui verse la paie la verse' using errcode = '42501';
    end if;
    if new.versement_mode is null then
      raise exception 'Indiquez le mode de versement' using errcode = '23514';
    end if;
    new.versee_par := auth.uid();
    new.versee_le := least(new.versee_le, current_date);
    if new.versement_mode = 'especes' and new.net_gnf > 0 then
      mois := to_char(p.mois, 'MM/YYYY');
      new.depense_id := scolagrid.depense_de_paie(new.organisation_id, new.personnel_id, new.net_gnf, 'Salaires', 'Salaire ' || mois);
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger ligne_paie_controle before insert or update or delete on public.lignes_paie
  for each row execute function scolagrid.ligne_paie_controle();

create or replace function scolagrid.avance_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.cree_par := auth.uid();
    if new.mode = 'especes' then
      new.depense_id := scolagrid.depense_de_paie(new.organisation_id, new.personnel_id, new.montant_gnf, 'Avances sur salaire',
        'Avance sur salaire' || coalesce(' : ' || new.motif, ''));
    end if;
  else
    -- Seuls le motif et la référence se corrigent : le montant est déjà sorti.
    if (new.montant_gnf, new.mode, new.personnel_id, new.date_avance) is distinct from (old.montant_gnf, old.mode, old.personnel_id, old.date_avance) then
      raise exception 'Une avance versée ne change pas de montant' using errcode = '23514';
    end if;
    new.depense_id := old.depense_id;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger avance_controle before insert or update on public.avances
  for each row execute function scolagrid.avance_controle();

revoke all on function scolagrid.paie_controle(), scolagrid.depense_paie(), scolagrid.ligne_paie_controle(), scolagrid.avance_controle()
  from public;

alter publication powersync add table public.remunerations, public.taux_horaires, public.grille_taux, public.avances,
  public.paies, public.lignes_paie;
