-- 021 : pièces du dossier réglables, documents bloqués si arriérés, seuil du tableau de bord.
--
-- * L'école tient sa liste de pièces : libellé, obligatoire ou non, pour
--   quelles admissions (nouvelle, réinscription, transfert) et quels cycles.
--   Une pièce obligatoire manquante est signalée, jamais bloquante.
-- * Documents (attestation, certificat) quand l'élève a des arriérés :
--   non (rien), alerte (on prévient), bloquer (la direction peut lever le
--   blocage avec un motif, gardé sur l'impression). Le reçu n'est jamais bloqué.
-- * Seuil de recouvrement du tableau de bord (70 % par défaut).

alter table public.organisations
  add column blocage_documents text not null default 'alerte' check (blocage_documents in ('non', 'alerte', 'bloquer')),
  add column seuil_recouvrement integer not null default 70 check (seuil_recouvrement between 0 and 100);

alter table public.impressions_documents
  add column motif_levee text check (motif_levee is null or length(trim(motif_levee)) between 3 and 200);

create table public.pieces_dossier (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  code text not null check (code ~ '^[a-z_]{2,30}$'),
  libelle text not null check (length(trim(libelle)) between 2 and 80),
  admissions text check (admissions is null or admissions ~ '^(nouvelle|reinscription|transfert)(,(nouvelle|reinscription|transfert))*$'),
  cycles text check (cycles is null or cycles ~ '^(maternelle|primaire|college|lycee)(,(maternelle|primaire|college|lycee))*$'),
  obligatoire boolean not null default false,
  ordre integer not null default 0,
  actif boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, code)
);
alter table public.pieces_dossier owner to postgres;
alter table public.pieces_dossier replica identity full;
alter table public.pieces_dossier enable row level security;
revoke all on public.pieces_dossier from anon, authenticated;
grant select on public.pieces_dossier to powersync_role;
grant select, insert, update, delete on public.pieces_dossier to authenticated;
create trigger maj_updated_at before update on public.pieces_dossier
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.pieces_dossier
  for each row execute function scolagrid.organisation_immuable();
create policy "membres lisent" on public.pieces_dossier for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "fondateur ajoute" on public.pieces_dossier for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur modifie" on public.pieces_dossier for update to authenticated
  using (scolagrid.est_fondateur(organisation_id)) with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur retire" on public.pieces_dossier for delete to authenticated
  using (scolagrid.est_fondateur(organisation_id));
alter publication powersync add table public.pieces_dossier;
