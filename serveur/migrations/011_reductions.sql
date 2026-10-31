-- 011 : réductions (fratrie, paiement annuel, personnalisées).
--
-- Règles définies par l'école : en pourcentage ou en montant fixe, sur la
-- scolarité, l'inscription ou tous les frais. La fratrie se calcule sur le
-- responsable financier (qui paie), selon un barème par nombre d'enfants.
-- Paiement annuel et réductions personnalisées sont attribués à une inscription.
-- Cumul au choix de l'école (avec plafond) ; sinon une seule réduction :
-- Fratrie, puis Paiement annuel, puis Personnalisée.
-- Le montant dû est calculé sur les postes (app/lib/caisse.dart) et, pour
-- l'activation de l'élève, par la même règle côté serveur (reduction_frais).

alter table public.organisations
  add column reductions_cumul boolean not null default false,
  add column reductions_plafond integer not null default 100 check (reductions_plafond between 0 and 100);

create table public.regles_reduction (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  type text not null check (type in ('fratrie', 'paiement_annuel', 'personnalisee')),
  libelle text not null check (length(trim(libelle)) between 2 and 80),   -- « Bourse 50 % », « 3 enfants »
  pourcentage boolean not null default true,
  valeur numeric(12, 2) not null check (valeur > 0),
  portee text not null default 'scolarite' check (portee in ('scolarite', 'inscription', 'tous')),
  nb_enfants integer check (nb_enfants is null or nb_enfants between 2 and 20),
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organisation_id),
  check (not pourcentage or valeur <= 100),
  -- Fratrie et paiement annuel portent sur la scolarité ; la fratrie a un seuil.
  check (type = 'personnalisee' or portee = 'scolarite'),
  check (type <> 'fratrie' or nb_enfants is not null)
);

create table public.reductions_eleves (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  inscription_id uuid not null,
  regle_id uuid not null,
  actif boolean not null default true,
  motif text check (motif is null or length(motif) <= 300),
  accorde_par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (inscription_id, regle_id),
  foreign key (inscription_id, organisation_id) references public.inscriptions (id, organisation_id) on delete cascade,
  foreign key (regle_id, organisation_id) references public.regles_reduction (id, organisation_id) on delete cascade
);

do $$
declare t text;
begin
  foreach t in array array['regles_reduction', 'reductions_eleves'] loop
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

create or replace function scolagrid.reduction_protegee() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated', 'anon') then new.accorde_par := auth.uid(); end if;
  else
    new.inscription_id := old.inscription_id;
    new.regle_id := old.regle_id;
    new.accorde_par := old.accorde_par;
  end if;
  return new;
end $$;
create trigger reduction_protegee before insert or update on public.reductions_eleves
  for each row execute function scolagrid.reduction_protegee();

-- Calcul -------------------------------------------------------------------------------

-- Nombre d'enfants inscrits cette année qui ont le même responsable financier.
create or replace function scolagrid.enfants_du_payeur(ins uuid) returns integer
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select count(distinct i2.id)::integer
    from public.inscriptions i
    join public.eleves_contacts ec on ec.eleve_id = i.eleve_id and ec.responsable_financier
    join public.eleves_contacts ec2 on ec2.contact_id = ec.contact_id and ec2.responsable_financier
    join public.inscriptions i2 on i2.eleve_id = ec2.eleve_id and i2.annee_id = i.annee_id
      and i2.statut not in ('annule', 'exclu', 'transfert_sortant')
    where i.id = ins), 1)
$$;

-- Réduction sur un frais d'une inscription (même règle que l'app).
create or replace function scolagrid.reduction_frais(ins uuid, type_frais text, total bigint) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare
  org uuid;
  cumul boolean;
  plafond integer;
  n integer := scolagrid.enfants_du_payeur(ins);
  r record;
  somme bigint := 0;
  premiere boolean := true;
begin
  select o.id, o.reductions_cumul, o.reductions_plafond into org, cumul, plafond
  from public.inscriptions i join public.organisations o on o.id = i.organisation_id where i.id = ins;
  for r in
    (select * from (
       -- Fratrie : le barème au seuil le plus haut atteint.
       (select g.*, 1 as rang, 0::bigint as ordre2 from public.regles_reduction g
        where g.organisation_id = org and g.actif and g.type = 'fratrie' and n >= 2 and g.nb_enfants <= n
        order by g.nb_enfants desc limit 1)
       union all
       (select g.*, case g.type when 'paiement_annuel' then 2 else 3 end, extract(epoch from g.created_at)::bigint
        from public.regles_reduction g
        join public.reductions_eleves re on re.regle_id = g.id and re.inscription_id = ins and re.actif
        where g.actif and g.type in ('paiement_annuel', 'personnalisee'))
     ) x order by rang, ordre2)
  loop
    -- Sans cumul, seule la première réduction (par priorité) compte.
    exit when not cumul and not premiere;
    premiere := false;
    if (r.portee = 'scolarite' and type_frais = 'scolarite')
       or (r.portee = 'inscription' and type_frais in ('inscription', 'reinscription'))
       or r.portee = 'tous' then
      somme := somme + case when r.pourcentage then floor(total * r.valeur / 100)::bigint
                            else least(r.valeur::bigint, total) end;
    end if;
  end loop;
  if cumul then somme := least(somme, floor(total * plafond / 100.0)::bigint); end if;
  return least(somme, total);
end $$;

revoke all on function scolagrid.enfants_du_payeur(uuid), scolagrid.reduction_frais(uuid, text, bigint) from public;

-- Activation : inscription payée, réduction déduite. Une inscription entièrement
-- couverte par une réduction (orphelin, bourse à 100 %) devient active d'office.
create or replace function scolagrid.verifier_activation(ins uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  i public.inscriptions;
  niveau uuid;
  brut bigint := 0;
  du bigint := 0;
  f record;
  paye bigint;
  premier date;
begin
  select * into i from public.inscriptions where id = ins;
  if i.statut <> 'en_attente' then return; end if;
  select niveau_id into niveau from public.classes where id = i.classe_id;
  for f in
    select fr.type_frais, fr.montant_gnf from public.frais fr
    where fr.annee_id = i.annee_id
      and fr.type_frais = case when i.type_admission = 'reinscription' then 'reinscription' else 'inscription' end
      and (fr.site_id is null or fr.site_id = i.site_id)
      and (fr.niveau_id is null or fr.niveau_id = niveau)
  loop
    brut := brut + f.montant_gnf;
    du := du + f.montant_gnf - scolagrid.reduction_frais(ins, f.type_frais, f.montant_gnf);
  end loop;
  select coalesce(sum(l.montant_gnf) filter (where fr.type_frais in ('inscription', 'reinscription')), 0),
         min(e.date_effective)
    into paye, premier
  from public.lignes_encaissement l
  join public.encaissements e on e.id = l.encaissement_id and e.statut = 'valide' and e.confirmation <> 'rejete'
  join public.frais fr on fr.id = l.frais_id
  where l.inscription_id = ins;
  if (premier is not null and paye >= du) or (brut > 0 and du = 0) then
    update public.inscriptions set statut = 'actif', date_actif = coalesce(premier, current_date) where id = ins;
  end if;
end $$;
revoke all on function scolagrid.verifier_activation(uuid) from public;

create or replace function scolagrid.apres_reduction() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform scolagrid.verifier_activation(new.inscription_id);
  return null;
end $$;
create trigger apres_reduction after insert or update on public.reductions_eleves
  for each row execute function scolagrid.apres_reduction();
revoke all on function scolagrid.apres_reduction() from public;

-- Règles d'accès ------------------------------------------------------------------------

-- Les règles : lues par tous les membres (calcul des montants dus) ; écrites par le fondateur.
grant select, insert, update on public.regles_reduction to authenticated;
create policy "membres lisent" on public.regles_reduction for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "fondateur ajoute" on public.regles_reduction for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur modifie" on public.regles_reduction for update to authenticated
  using (scolagrid.est_fondateur(organisation_id)) with check (scolagrid.est_fondateur(organisation_id));

-- Attribution : une réduction personnalisée par la direction du site de l'élève ;
-- le paiement annuel aussi par la caisse, au moment où la famille paie l'année.
create or replace function scolagrid.peut_attribuer(ins uuid, regle uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.inscriptions i join public.regles_reduction g on g.id = regle and g.organisation_id = i.organisation_id
    where i.id = ins and g.type <> 'fratrie' and (
      scolagrid.gere_site(i.organisation_id, i.site_id)
      or (g.type = 'paiement_annuel' and scolagrid.a_le_droit(i.organisation_id, i.site_id, 'encaisser'))))
$$;
revoke all on function scolagrid.peut_attribuer(uuid, uuid) from public;
grant execute on function scolagrid.peut_attribuer(uuid, uuid) to authenticated;

grant select, insert, update on public.reductions_eleves to authenticated;
create policy "membres lisent" on public.reductions_eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "direction ou caisse attribue" on public.reductions_eleves for insert to authenticated
  with check (scolagrid.peut_attribuer(inscription_id, regle_id));
create policy "direction ou caisse modifie" on public.reductions_eleves for update to authenticated
  using (scolagrid.peut_attribuer(inscription_id, regle_id)) with check (scolagrid.peut_attribuer(inscription_id, regle_id));

alter publication powersync add table public.regles_reduction, public.reductions_eleves;
