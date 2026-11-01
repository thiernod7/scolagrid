-- 020 : l'école sur ses documents.
--
-- Contacts, adresse, autorisation d'ouverture, NIF, date de création ;
-- mention en bas des reçus ; logo, signature et cachet scannés.
-- Le logo est vu de tous les membres. La signature et le cachet, qui
-- authentifient un document, seulement par ceux qui en impriment
-- (droit d'inscrire, ou fondateur). Seul le fondateur les change.

alter table public.organisations
  add column telephone2 text check (telephone2 is null or telephone2 ~ '^\+?[0-9 ]{8,20}$'),
  add column site_web text check (site_web is null or length(site_web) between 4 and 120),
  add column commune text check (commune is null or length(commune) <= 80),
  add column responsable_telephone text check (responsable_telephone is null or responsable_telephone ~ '^\+?[0-9 ]{8,20}$'),
  add column responsable_email text check (responsable_email is null or responsable_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column numero_autorisation text check (numero_autorisation is null or length(trim(numero_autorisation)) between 2 and 80),
  add column nif text check (nif is null or length(trim(nif)) between 2 and 40),
  add column date_creation date,
  add column mention_recu text check (mention_recu is null or length(trim(mention_recu)) between 2 and 200),
  add column signature_documents boolean not null default false;

create table public.images_ecole (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  sorte text not null check (sorte in ('logo', 'signature', 'cachet')),
  type_image text not null check (type_image in ('image/jpeg', 'image/png')),
  image text not null check (length(image) between 100 and 400000),
  par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organisation_id, sorte)
);
alter table public.images_ecole owner to postgres;
alter table public.images_ecole replica identity full;
alter table public.images_ecole enable row level security;
revoke all on public.images_ecole from anon, authenticated;
grant select on public.images_ecole to powersync_role;
grant select, insert, update, delete on public.images_ecole to authenticated;
create trigger maj_updated_at before update on public.images_ecole
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.images_ecole
  for each row execute function scolagrid.organisation_immuable();

create or replace function scolagrid.image_ecole_auteur() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then new.par := auth.uid(); end if;
  if tg_op = 'UPDATE' then new.sorte := old.sorte; end if;
  return new;
end $$;
create trigger image_ecole_auteur before insert or update on public.images_ecole
  for each row execute function scolagrid.image_ecole_auteur();

create policy "logo pour tous, signature pour qui imprime" on public.images_ecole for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations())
         and (sorte = 'logo' or scolagrid.est_fondateur(organisation_id)
              or scolagrid.a_le_droit_quelque_part(organisation_id, 'gerer_inscriptions')));
create policy "fondateur ajoute" on public.images_ecole for insert to authenticated
  with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur change" on public.images_ecole for update to authenticated
  using (scolagrid.est_fondateur(organisation_id)) with check (scolagrid.est_fondateur(organisation_id));
create policy "fondateur retire" on public.images_ecole for delete to authenticated
  using (scolagrid.est_fondateur(organisation_id));
alter publication powersync add table public.images_ecole;
