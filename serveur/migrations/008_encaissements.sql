-- 008 : encaissements (reçus) et frais souscrits.
--
-- Un encaissement = un reçu : un payeur, un mode, une date, une feuille du
-- carnet papier, un numéro système créé par le poste (REC-ALPHA-DONKA-2026-B0042).
-- Il porte une ou plusieurs lignes : un élève, un frais, un montant. On ne
-- supprime jamais un reçu : on l'annule (motif obligatoire), il reste dans la
-- suite des numéros. L'inscription passe « active » quand ses frais
-- d'inscription (ou de réinscription) sont payés.

-- Frais optionnels choisis par un élève (cantine, transport…). Les autres frais
-- (inscription, réinscription, scolarité) s'appliquent d'office selon le niveau.
create table public.souscriptions (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  inscription_id uuid not null,
  frais_id uuid not null,
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (inscription_id, frais_id),
  foreign key (inscription_id, organisation_id) references public.inscriptions (id, organisation_id) on delete cascade,
  foreign key (frais_id, organisation_id) references public.frais (id, organisation_id) on delete cascade
);

create table public.encaissements (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid not null,
  annee_id uuid not null,
  numero text not null unique check (numero ~ '^REC-[A-Z0-9]{2,10}-[A-Z0-9]{2,10}-[0-9]{4}-[A-Z]{1,3}[0-9]{4,7}$'),
  carnet text check (carnet is null or length(carnet) <= 40),          -- « Vert n° 3 »
  feuille text check (feuille is null or length(feuille) <= 20),       -- numéro imprimé sur le reçu papier
  payeur_nom text not null check (length(trim(payeur_nom)) between 2 and 120),
  payeur_contact_id uuid,
  mode text not null check (mode in ('especes', 'cheque', 'virement', 'orange_money', 'mtn_money')),
  reference text check (reference is null or length(reference) <= 60),
  date_effective date not null default current_date,
  total_gnf bigint not null check (total_gnf > 0),
  confirmation text not null default 'confirme' check (confirmation in ('confirme', 'en_attente', 'rejete')),
  statut text not null default 'valide' check (statut in ('valide', 'annule')),
  motif_annulation text check (motif_annulation is null or length(motif_annulation) <= 300),
  annule_par uuid references auth.users (id) on delete set null,
  annule_le timestamptz,
  impressions integer not null default 0 check (impressions >= 0),
  poste_id uuid references public.postes (id) on delete set null,
  encaisse_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),         -- date technique, immuable
  updated_at timestamptz not null default now(),
  unique (id, organisation_id),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id),
  foreign key (annee_id, organisation_id) references public.annees_scolaires (id, organisation_id),
  foreign key (payeur_contact_id, organisation_id) references public.contacts (id, organisation_id),
  check (statut = 'valide' or motif_annulation is not null)
);
create index encaissements_jour_idx on public.encaissements (organisation_id, date_effective);
-- Une feuille du carnet papier ne sert qu'une fois.
create unique index encaissements_feuille_unique on public.encaissements (organisation_id, carnet, feuille)
  where feuille is not null;

create table public.lignes_encaissement (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  encaissement_id uuid not null,
  inscription_id uuid not null,
  eleve_id uuid not null,
  frais_id uuid not null,
  montant_gnf bigint not null check (montant_gnf > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (encaissement_id, organisation_id) references public.encaissements (id, organisation_id) on delete cascade,
  foreign key (inscription_id, organisation_id) references public.inscriptions (id, organisation_id),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id),
  foreign key (frais_id, organisation_id) references public.frais (id, organisation_id)
);
create index lignes_encaissement_inscription_idx on public.lignes_encaissement (inscription_id);
create index lignes_encaissement_encaissement_idx on public.lignes_encaissement (encaissement_id);

do $$
declare t text;
begin
  foreach t in array array['souscriptions', 'encaissements', 'lignes_encaissement'] loop
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

-- Un reçu émis ne se modifie pas : seuls l'annulation, la confirmation
-- (chèque, virement) et le compteur d'impressions changent.
create or replace function scolagrid.encaissement_protege() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated', 'anon') then
      new.encaisse_par := auth.uid();
      new.statut := 'valide';
      new.annule_par := null;
      new.annule_le := null;
      new.impressions := 0;
      new.confirmation := case when new.mode in ('cheque', 'virement') then 'en_attente' else 'confirme' end;
    end if;
    return new;
  end if;
  new.site_id := old.site_id;
  new.annee_id := old.annee_id;
  new.numero := old.numero;
  new.carnet := old.carnet;
  new.feuille := old.feuille;
  new.payeur_nom := old.payeur_nom;
  new.payeur_contact_id := old.payeur_contact_id;
  new.mode := old.mode;
  new.reference := old.reference;
  new.date_effective := old.date_effective;
  new.total_gnf := old.total_gnf;
  new.poste_id := old.poste_id;
  new.encaisse_par := old.encaisse_par;
  new.created_at := old.created_at;
  new.impressions := greatest(old.impressions, new.impressions);
  if old.statut = 'annule' then
    new.statut := 'annule';
    new.motif_annulation := old.motif_annulation;
    new.annule_par := old.annule_par;
    new.annule_le := old.annule_le;
  elsif new.statut = 'annule' then
    if current_user in ('authenticated', 'anon') and not (
         scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu')
         or (old.encaisse_par = auth.uid() and old.created_at > now() - interval '24 hours')) then
      raise exception 'Annulation réservée à l''encaisseur (24 h) ou au titulaire du droit' using errcode = '42501';
    end if;
    new.annule_par := coalesce(auth.uid(), new.annule_par);
    new.annule_le := now();
  end if;
  if new.confirmation is distinct from old.confirmation and current_user in ('authenticated', 'anon')
     and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'annuler_recu') then
    new.confirmation := old.confirmation;
  end if;
  return new;
end $$;
create trigger encaissement_protege before insert or update on public.encaissements
  for each row execute function scolagrid.encaissement_protege();

-- Les lignes d'un reçu ne changent plus une fois écrites.
create or replace function scolagrid.ligne_figee() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Une ligne de reçu ne se modifie pas : annulez le reçu' using errcode = '42501';
end $$;
create trigger ligne_figee before update on public.lignes_encaissement
  for each row execute function scolagrid.ligne_figee();

-- Inscription active : frais d'inscription (ou de réinscription) entièrement payés.
-- S'il n'y a pas de tels frais pour sa classe, le premier paiement suffit.
create or replace function scolagrid.verifier_activation(ins uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  i public.inscriptions;
  niveau uuid;
  du bigint;
  paye bigint;
  premier date;
begin
  select * into i from public.inscriptions where id = ins;
  if i.statut <> 'en_attente' then return; end if;
  select niveau_id into niveau from public.classes where id = i.classe_id;
  select coalesce(sum(f.montant_gnf), 0) into du from public.frais f
  where f.annee_id = i.annee_id
    and f.type_frais = case when i.type_admission = 'reinscription' then 'reinscription' else 'inscription' end
    and (f.site_id is null or f.site_id = i.site_id)
    and (f.niveau_id is null or f.niveau_id = niveau);
  select coalesce(sum(l.montant_gnf) filter (where f.type_frais in ('inscription', 'reinscription')), 0),
         min(e.date_effective)
    into paye, premier
  from public.lignes_encaissement l
  join public.encaissements e on e.id = l.encaissement_id and e.statut = 'valide' and e.confirmation <> 'rejete'
  join public.frais f on f.id = l.frais_id
  where l.inscription_id = ins;
  if premier is not null and paye >= du then
    update public.inscriptions set statut = 'actif', date_actif = premier where id = ins;
  end if;
end $$;
revoke all on function scolagrid.verifier_activation(uuid) from public;

create or replace function scolagrid.apres_ligne() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform scolagrid.verifier_activation(new.inscription_id);
  return null;
end $$;
create trigger apres_ligne after insert on public.lignes_encaissement
  for each row execute function scolagrid.apres_ligne();
revoke all on function scolagrid.apres_ligne() from public;

-- Règles d'accès ---------------------------------------------------------------------

-- Lecture : ceux qui encaissent ou inscrivent, et la direction (tableau de bord).
create or replace function scolagrid.voit_caisse(org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select scolagrid.voit_familles(org) or scolagrid.a_le_droit_quelque_part(org, 'consulter_tableau_bord')
$$;
revoke all on function scolagrid.voit_caisse(uuid) from public;
grant execute on function scolagrid.voit_caisse(uuid) to authenticated;

grant select, insert, update on public.encaissements to authenticated;
create policy "caisse : lecture" on public.encaissements for select to authenticated
  using (scolagrid.voit_caisse(organisation_id));
create policy "caisse : encaissement" on public.encaissements for insert to authenticated
  with check (scolagrid.a_le_droit(organisation_id, site_id, 'encaisser'));
-- Annulation, confirmation et impressions : contrôlées par le déclencheur ci-dessus.
create policy "caisse : suivi du reçu" on public.encaissements for update to authenticated
  using (scolagrid.a_le_droit(organisation_id, site_id, 'encaisser')
         or scolagrid.a_le_droit(organisation_id, site_id, 'annuler_recu'))
  with check (true);

grant select, insert on public.lignes_encaissement to authenticated;
create policy "caisse : lecture" on public.lignes_encaissement for select to authenticated
  using (scolagrid.voit_caisse(organisation_id));
-- Une ligne s'ajoute à un reçu valide de l'encaisseur, pour une inscription de la même école.
create policy "caisse : ligne" on public.lignes_encaissement for insert to authenticated
  with check (exists (select 1 from public.encaissements e
                      where e.id = encaissement_id and e.encaisse_par = auth.uid() and e.statut = 'valide'));

grant select, insert, update on public.souscriptions to authenticated;
create policy "membres lisent" on public.souscriptions for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "inscripteur ou caissier souscrit" on public.souscriptions for insert to authenticated
  with check (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions')
              or scolagrid.a_le_droit_quelque_part(organisation_id, 'encaisser'));
create policy "inscripteur ou caissier modifie" on public.souscriptions for update to authenticated
  using (scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions')
         or scolagrid.a_le_droit_quelque_part(organisation_id, 'encaisser'))
  with check (true);

alter publication powersync add table public.souscriptions, public.encaissements, public.lignes_encaissement;
