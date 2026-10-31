-- 014 : remboursements.
--
-- Exceptionnels : un paiement n'est jamais supprimé ; un remboursement est une
-- opération distincte, liée à une ligne de reçu, avec motif obligatoire.
-- Circuit : la caisse enregistre la DEMANDE → le titulaire du droit
-- « valider_remboursement » AUTORISE (ou refuse) → la caisse VERSE l'argent
-- contre une décharge signée par le parent. Politique de l'école, frais par
-- frais, avec un interrupteur « aucun remboursement » qui prime sur tout.
-- Un remboursement versé en espèces sort de la caisse du jour (clôture).

alter table public.organisations
  add column remboursement_aucun boolean not null default false,
  add column remboursable_inscription boolean not null default false,
  add column remboursable_reinscription boolean not null default false,
  add column remboursable_scolarite boolean not null default true,
  add column remboursable_optionnel boolean not null default true;

alter table public.lignes_encaissement add constraint lignes_id_organisation_unique unique (id, organisation_id);

create table public.remboursements (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid not null,
  ligne_id uuid not null,                 -- ligne de reçu remboursée (un élève, un frais)
  encaissement_id uuid not null,
  inscription_id uuid not null,
  eleve_id uuid not null,
  frais_id uuid not null,
  montant_gnf bigint not null check (montant_gnf > 0),
  beneficiaire text not null check (length(trim(beneficiaire)) between 2 and 120),
  motif text not null check (length(trim(motif)) between 3 and 300),
  mode text not null default 'especes' check (mode in ('especes', 'orange_money', 'mtn_money', 'cheque', 'virement')),
  statut text not null default 'demande' check (statut in ('demande', 'autorise', 'refuse', 'verse')),
  demande_par uuid references auth.users (id) on delete set null,
  autorise_par uuid references auth.users (id) on delete set null,
  autorise_le timestamptz,
  motif_refus text check (motif_refus is null or length(trim(motif_refus)) between 3 and 300),
  verse_par uuid references auth.users (id) on delete set null,
  verse_le date,
  decharge text check (decharge is null or length(decharge) <= 60),   -- carnet et n° de la décharge papier
  poste_id uuid references public.postes (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id),
  foreign key (ligne_id, organisation_id) references public.lignes_encaissement (id, organisation_id),
  foreign key (encaissement_id, organisation_id) references public.encaissements (id, organisation_id),
  foreign key (inscription_id, organisation_id) references public.inscriptions (id, organisation_id),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id),
  foreign key (frais_id, organisation_id) references public.frais (id, organisation_id)
);
create index remboursements_inscription_idx on public.remboursements (inscription_id);

alter table public.remboursements owner to postgres;
alter table public.remboursements replica identity full;
alter table public.remboursements enable row level security;
revoke all on public.remboursements from anon, authenticated;
grant select on public.remboursements to powersync_role;
create trigger maj_updated_at before update on public.remboursements
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.remboursements
  for each row execute function scolagrid.organisation_immuable();

-- Règles du circuit, vérifiées par le serveur.
create or replace function scolagrid.remboursement_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  l record;
  o public.organisations;
  deja bigint;
  remboursable boolean;
  connecte boolean := nullif(current_setting('request.jwt.claim.sub', true), '') is not null;
begin
  if tg_op = 'INSERT' then
    select li.*, e.statut as statut_recu, e.site_id as site_recu, f.type_frais
      into l
    from public.lignes_encaissement li
    join public.encaissements e on e.id = li.encaissement_id
    join public.frais f on f.id = li.frais_id
    where li.id = new.ligne_id and li.organisation_id = new.organisation_id;
    if not found or l.statut_recu <> 'valide' then
      raise exception 'Seule une ligne d''un reçu valide peut être remboursée' using errcode = '23514';
    end if;
    -- Les références suivent la ligne : on ne peut pas les choisir.
    new.encaissement_id := l.encaissement_id;
    new.inscription_id := l.inscription_id;
    new.eleve_id := l.eleve_id;
    new.frais_id := l.frais_id;
    new.site_id := l.site_recu;
    new.statut := 'demande';
    new.autorise_par := null; new.autorise_le := null; new.verse_par := null; new.verse_le := null;
    if connecte then new.demande_par := auth.uid(); end if;
    select * into o from public.organisations where id = new.organisation_id;
    remboursable := case l.type_frais
         when 'inscription' then o.remboursable_inscription
         when 'reinscription' then o.remboursable_reinscription
         when 'scolarite' then o.remboursable_scolarite
         else o.remboursable_optionnel end;
    if o.remboursement_aucun or not remboursable then
      raise exception 'Ces frais ne sont pas remboursables selon la politique de l''école' using errcode = '23514';
    end if;
    select coalesce(sum(montant_gnf), 0) into deja from public.remboursements
    where ligne_id = new.ligne_id and statut <> 'refuse';
    if new.montant_gnf + deja > l.montant_gnf then
      raise exception 'Le remboursement dépasse ce qui a été payé' using errcode = '23514';
    end if;
    return new;
  end if;

  -- Mise à jour : seules les étapes du circuit, dans l'ordre.
  new.ligne_id := old.ligne_id; new.encaissement_id := old.encaissement_id; new.inscription_id := old.inscription_id;
  new.eleve_id := old.eleve_id; new.frais_id := old.frais_id; new.site_id := old.site_id;
  new.montant_gnf := old.montant_gnf; new.motif := old.motif; new.demande_par := old.demande_par;
  new.created_at := old.created_at;
  if new.statut = old.statut then
    -- Rien d'autre ne change hors d'une étape (le bénéficiaire et le mode restent ceux de la demande).
    new.beneficiaire := old.beneficiaire; new.mode := old.mode; new.motif_refus := old.motif_refus;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le;
    new.verse_par := old.verse_par; new.verse_le := old.verse_le; new.decharge := old.decharge;
    return new;
  end if;
  if old.statut = 'demande' and new.statut in ('autorise', 'refuse') then
    if connecte and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'valider_remboursement') then
      raise exception 'Autoriser un remboursement demande le droit « valider un remboursement »' using errcode = '42501';
    end if;
    if new.statut = 'refuse' and new.motif_refus is null then
      raise exception 'Un refus doit être motivé' using errcode = '23514';
    end if;
    new.autorise_par := case when connecte then auth.uid() else new.autorise_par end;
    new.autorise_le := now();
    new.verse_par := null; new.verse_le := null;
    return new;
  end if;
  if old.statut = 'autorise' and new.statut = 'verse' then
    if connecte and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'encaisser') then
      raise exception 'Verser un remboursement demande le droit « encaisser »' using errcode = '42501';
    end if;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le; new.motif_refus := old.motif_refus;
    if connecte then new.verse_par := auth.uid(); end if;
    new.verse_le := coalesce(new.verse_le, current_date);
    return new;
  end if;
  raise exception 'Étape de remboursement impossible : % → %', old.statut, new.statut using errcode = '23514';
end $$;
create trigger remboursement_controle before insert or update on public.remboursements
  for each row execute function scolagrid.remboursement_controle();
revoke all on function scolagrid.remboursement_controle() from public;

-- La clôture compte les remboursements versés en espèces comme des sorties de caisse.
create or replace function scolagrid.cloture_calculee() returns trigger
language plpgsql security definer set search_path = '' as $$
declare sorties bigint;
begin
  if tg_op = 'UPDATE' then
    raise exception 'Une clôture de caisse ne se modifie pas' using errcode = '42501';
  end if;
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
  new.attendu_especes := new.attendu_especes - sorties;
  new.ecart := new.compte_especes - new.attendu_especes;
  if new.ecart <> 0 and new.justification is null then
    raise exception 'Un écart de caisse doit être justifié' using errcode = '23514';
  end if;
  return new;
end $$;

-- La décharge est un document officiel, notée comme les attestations.
alter table public.impressions_documents drop constraint impressions_documents_type_document_check;
alter table public.impressions_documents add constraint impressions_documents_type_document_check
  check (type_document in ('attestation_inscription', 'certificat_scolarite', 'decharge_remboursement'));

-- Règles d'accès : la caisse et la direction lisent ; la caisse demande ; le
-- circuit (autoriser, refuser, verser) est contrôlé par le déclencheur ci-dessus.
grant select, insert, update on public.remboursements to authenticated;
create policy "caisse : lecture" on public.remboursements for select to authenticated
  using (scolagrid.voit_caisse(organisation_id));
create policy "caisse : demande" on public.remboursements for insert to authenticated
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'encaisser'));
create policy "circuit du remboursement" on public.remboursements for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'encaisser')
         or scolagrid.a_le_droit(organisation_id, site_id, 'valider_remboursement'))
  with check (true);

alter publication powersync add table public.remboursements;
