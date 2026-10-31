-- 015 : photos d'identité des élèves.
--
-- Hors ligne d'abord : la photo est réduite sur le poste (environ 400 px,
-- quelques dizaines de Ko) et rangée dans la base comme le reste ; elle
-- s'affiche donc sans réseau, sur tous les postes de l'école. Une photo par
-- élève, remplacée quand on la change. Limite de taille contrôlée ici.

create table public.photos_eleves (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations (id) on delete cascade,
  eleve_id uuid not null unique,
  type_image text not null check (type_image in ('image/jpeg', 'image/png')),
  image text not null check (length(image) between 100 and 400000),   -- base64, 300 Ko au plus
  par uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (eleve_id, organisation_id) references public.eleves (id, organisation_id) on delete cascade
);

alter table public.photos_eleves owner to postgres;
alter table public.photos_eleves replica identity full;
alter table public.photos_eleves enable row level security;
revoke all on public.photos_eleves from anon, authenticated;
grant select on public.photos_eleves to powersync_role;
create trigger maj_updated_at before update on public.photos_eleves
  for each row execute function scolagrid.maj_updated_at();
create trigger organisation_immuable before update on public.photos_eleves
  for each row execute function scolagrid.organisation_immuable();

create or replace function scolagrid.photo_auteur() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.eleve_id := coalesce(old.eleve_id, new.eleve_id);
  if current_user in ('authenticated', 'anon') then new.par := auth.uid(); end if;
  return new;
end $$;
create trigger photo_auteur before insert or update on public.photos_eleves
  for each row execute function scolagrid.photo_auteur();

-- Tous les membres voient les photos (l'enseignant reconnaît ses élèves) ;
-- ceux qui inscrivent les prennent et les changent.
grant select, insert, update, delete on public.photos_eleves to authenticated;
create policy "membres lisent" on public.photos_eleves for select to authenticated
  using (organisation_id in (select scolagrid.mes_organisations()));
create policy "inscripteur ajoute" on public.photos_eleves for insert to authenticated
  with check (scolagrid.peut_editer_documents(eleve_id));
create policy "inscripteur change" on public.photos_eleves for update to authenticated
  using (scolagrid.peut_editer_documents(eleve_id)) with check (scolagrid.peut_editer_documents(eleve_id));
create policy "inscripteur retire" on public.photos_eleves for delete to authenticated
  using (scolagrid.peut_editer_documents(eleve_id));

alter publication powersync add table public.photos_eleves;
