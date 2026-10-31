-- 013 : documents officiels imprimés (attestation d'inscription, puis certificat
-- de scolarité). Chaque impression est notée : qui, quand, sur quel poste.
-- La première est l'ORIGINAL ; toute réimpression est un DUPLICATA numéroté,
-- avec son motif — même règle que pour les reçus.

create table public.impressions_documents (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  eleve_id uuid not null,
  inscription_id uuid,
  type_document text not null check (type_document in ('attestation_inscription', 'certificat_scolarite')),
  rang integer not null check (rang >= 1),            -- 1 = original, 2 = duplicata n°1…
  motif text check (motif is null or length(trim(motif)) between 3 and 300),
  par uuid references auth.users (id) on delete set null,
  poste_id uuid references public.postes (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id) on delete cascade,
  foreign key (inscription_id, organisation_id) references public.inscriptions (id, organisation_id) on delete cascade,
  check (rang = 1 or motif is not null)
);
create index impressions_documents_eleve_idx on public.impressions_documents (eleve_id);

alter table public.impressions_documents owner to postgres;
alter table public.impressions_documents replica identity full;
alter table public.impressions_documents enable row level security;
revoke all on public.impressions_documents from anon, authenticated;
grant select on public.impressions_documents to powersync_role;

-- Le journal ne se modifie pas ; l'auteur est celui qui est connecté.
create or replace function scolagrid.impression_notee() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'Le journal des impressions ne se modifie pas' using errcode = '42501';
  end if;
  if current_user in ('authenticated', 'anon') then new.par := auth.uid(); end if;
  return new;
end $$;
create trigger impression_notee before insert or update on public.impressions_documents
  for each row execute function scolagrid.impression_notee();

-- Imprimer un document officiel : ceux qui ont le droit d'inscrire sur le site de l'élève.
create or replace function scolagrid.peut_editer_documents(eleve uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select scolagrid.a_le_droit(e.organisation_id, e.site_id, 'gerer_inscriptions')
                   from public.eleves e where e.id = eleve), false)
$$;
revoke all on function scolagrid.peut_editer_documents(uuid) from public;
grant execute on function scolagrid.peut_editer_documents(uuid) to authenticated;

grant select, insert on public.impressions_documents to authenticated;
create policy "membres lisent" on public.impressions_documents for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "inscripteur imprime" on public.impressions_documents for insert to authenticated
  with check (scolagrid.peut_editer_documents(eleve_id));

alter publication powersync add table public.impressions_documents;
