-- 005 : postes de travail (étape 4 de l'onboarding).
--
-- Chaque appareil qui utilise Scolagrid est activé une fois, en ligne. Il reçoit
-- un code propre à l'organisation (A, B, … Z, AA, AB…), jamais réutilisé : le
-- poste s'en sert pour fabriquer seul, hors ligne, des numéros uniques
-- (matricules, reçus), par ex. ALPHA-DONKA-2025-B042.
--
-- Le gestionnaire du site voit les postes et peut en bloquer un (appareil perdu
-- ou volé) : à sa prochaine synchronisation, le poste efface ses données.

create table public.postes (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  site_id uuid,                                  -- vide = poste du groupe (fondateur)
  numero integer not null check (numero >= 1),
  code text not null check (code ~ '^[A-Z]{1,3}$'),
  nom text not null check (length(trim(nom)) between 2 and 60),   -- « PC du secrétariat »
  plateforme text check (plateforme is null or length(plateforme) <= 20),
  version_app text check (version_app is null or length(version_app) <= 20),
  user_id uuid references auth.users (id) on delete set null,      -- qui l'a activé
  statut text not null default 'actif' check (statut in ('actif', 'bloque')),
  derniere_synchro timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, numero),
  unique (organisation_id, code),
  foreign key (site_id, organisation_id) references public.sites (id, organisation_id) on delete cascade
);
create index postes_site_idx on public.postes (site_id);
create index postes_user_idx on public.postes (user_id);

alter table public.postes owner to postgres;
alter table public.postes replica identity full;
alter table public.postes enable row level security;
revoke all on public.postes from anon, authenticated;
grant select on public.postes to powersync_role;
create trigger maj_updated_at before update on public.postes
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.postes
  for each row execute function scolagrid.organisation_immuable();

-- Depuis l'app : le gestionnaire renomme, bloque ou débloque ; le poste lui-même
-- (la personne qui l'a activé) ne signale que sa dernière synchro et sa version.
-- Le code, le numéro, le site et l'auteur de l'activation ne changent jamais.
create or replace function scolagrid.poste_protege() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.numero := old.numero;
  new.code := old.code;
  if current_user in ('authenticated', 'anon') then
    new.site_id := old.site_id;
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if not scolagrid.gere_perimetre(old.organisation_id, old.site_id) then
      new.nom := old.nom;
      new.statut := old.statut;
    end if;
    if old.user_id is distinct from auth.uid() then
      new.derniere_synchro := old.derniere_synchro;
      new.version_app := old.version_app;
      new.plateforme := old.plateforme;
    end if;
  end if;
  return new;
end $$;
create trigger poste_protege before update on public.postes
  for each row execute function scolagrid.poste_protege();

-- « 1 » → A, « 26 » → Z, « 27 » → AA, « 28 » → AB…
create or replace function scolagrid.code_poste(n integer) returns text
language plpgsql immutable set search_path = '' as $$
declare
  reste integer := n;
  code text := '';
begin
  while reste > 0 loop
    code := chr(65 + (reste - 1) % 26) || code;
    reste := (reste - 1) / 26;
  end loop;
  return code;
end $$;

-- Puis-je travailler sur ce site ? (site vide : poste du groupe, réservé au fondateur)
create or replace function scolagrid.travaille_sur(org uuid, site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when site is null then scolagrid.est_fondateur(org)
         else exists (select 1 from public.rattachements
                      where user_id = auth.uid() and actif and organisation_id = org
                        and (site_id is null or site_id = travaille_sur.site)) end
$$;
revoke all on function scolagrid.travaille_sur(uuid, uuid) from public;
grant execute on function scolagrid.travaille_sur(uuid, uuid) to authenticated;

grant select, update on public.postes to authenticated;
create policy "le poste et ses gestionnaires lisent" on public.postes for select to authenticated
  using (user_id = auth.uid() or scolagrid.gere_perimetre(organisation_id, site_id));
create policy "le poste et ses gestionnaires modifient" on public.postes for update to authenticated
  using (user_id = auth.uid() or scolagrid.gere_perimetre(organisation_id, site_id))
  with check (user_id = auth.uid() or scolagrid.gere_perimetre(organisation_id, site_id));

-- Active ce poste : lui attribue le code suivant de l'organisation. En ligne seulement.
create or replace function public.activer_poste(
  organisation uuid, site uuid, nom text, plateforme text default null, version_app text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  moi uuid := auth.uid();
  suivant integer;
  poste public.postes;
begin
  if moi is null or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'is_anonymous')::boolean, false) then
    raise exception 'Connexion par téléphone requise' using errcode = '42501';
  end if;
  if not scolagrid.travaille_sur(organisation, site) then
    raise exception 'Vous ne travaillez pas sur ce site' using errcode = '42501';
  end if;
  -- Un seul calcul de code à la fois par organisation.
  perform 1 from public.organisations where id = organisation for update;
  select coalesce(max(numero), 0) + 1 into suivant from public.postes where organisation_id = organisation;
  if suivant > 2000 then
    raise exception 'Nombre maximal de postes atteint' using errcode = '54000';
  end if;

  insert into public.postes (organisation_id, site_id, numero, code, nom, plateforme, version_app, user_id, derniere_synchro)
  values (organisation, site, suivant, scolagrid.code_poste(suivant), trim(nom),
          left(plateforme, 20), left(version_app, 20), moi, now())
  returning * into poste;
  return jsonb_build_object('id', poste.id, 'code', poste.code);
end $$;

revoke all on function public.activer_poste(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.activer_poste(uuid, uuid, text, text, text) to authenticated;

alter publication powersync add table public.postes;
