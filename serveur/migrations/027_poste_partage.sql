-- 027 : un poste appartient à l'appareil, pas à la personne.
--
-- Quand quelqu'un se déconnecte, l'appareil garde son poste (sa lettre) ; le
-- compte suivant de la même école le reprend. Les membres qui travaillent sur
-- le site du poste le voient donc (pour savoir s'il est bloqué) et peuvent
-- signaler sa synchronisation ; seuls la direction change son nom ou son statut.

create policy "membres du site lisent" on public.postes for select to authenticated
  using (scolagrid.travaille_sur(organisation_id, site_id));

drop policy "le poste et ses gestionnaires modifient" on public.postes;
create policy "le poste, ses utilisateurs et ses gestionnaires modifient" on public.postes for update to authenticated
  using (user_id = auth.uid() or scolagrid.gere_perimetre(organisation_id, site_id) or scolagrid.travaille_sur(organisation_id, site_id))
  with check (user_id = auth.uid() or scolagrid.gere_perimetre(organisation_id, site_id) or scolagrid.travaille_sur(organisation_id, site_id));

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
    -- Synchro, version et plateforme : signalées par qui utilise le poste.
    if old.user_id is distinct from auth.uid() and not scolagrid.travaille_sur(old.organisation_id, old.site_id) then
      new.derniere_synchro := old.derniere_synchro;
      new.version_app := old.version_app;
      new.plateforme := old.plateforme;
    end if;
  end if;
  return new;
end $$;
