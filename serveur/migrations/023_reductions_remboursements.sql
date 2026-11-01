-- 023 : réductions et remboursements enrichis.
--
-- « Enfant du personnel » : une réduction accordée élève par élève, en
-- nommant le parent membre du personnel. Priorité sans cumul : fratrie, enfant
-- du personnel, paiement annuel, personnalisée.
-- Réductions personnalisées : un motif obligatoire et une durée en années.
-- Elles ne se reconduisent jamais seules : à la réinscription, la direction
-- reconduit (année 2 sur 3…) ou non.
-- Remboursement autorisé de vive voix : la caisse note qui l'a autorisé et
-- peut verser ; la direction confirme (ou conteste) dans l'application, sous
-- un délai (48 h par défaut) au-delà duquel il est signalé en retard.

-- Réductions --------------------------------------------------------------------------

alter table public.regles_reduction drop constraint regles_reduction_type_check;
alter table public.regles_reduction add constraint regles_reduction_type_check
  check (type in ('fratrie', 'paiement_annuel', 'personnalisee', 'personnel'));
alter table public.regles_reduction drop constraint regles_reduction_check1;
alter table public.regles_reduction add constraint regles_reduction_portee_par_type
  check (type in ('personnalisee', 'personnel') or portee = 'scolarite');

alter table public.reductions_eleves
  add column personnel_id uuid,
  add column duree_annees integer not null default 1 check (duree_annees between 1 and 6),
  add column annee_rang integer not null default 1 check (annee_rang between 1 and 6),
  add column reconduite_de uuid references public.reductions_eleves (id) on delete set null,
  add constraint reductions_rang_dans_duree check (annee_rang <= duree_annees),
  add constraint reductions_eleves_personnel
    foreign key (personnel_id, organisation_id) references public.personnel (id, organisation_id);

create or replace function scolagrid.reduction_protegee() returns trigger
language plpgsql set search_path = '' as $$
declare
  t text;
  avant public.reductions_eleves;
begin
  if tg_op = 'INSERT' then
    if current_user in ('authenticated', 'anon') then new.accorde_par := auth.uid(); end if;
    select type into t from public.regles_reduction where id = new.regle_id;
    if t in ('personnalisee', 'personnel') and (new.motif is null or length(trim(new.motif)) < 3) then
      raise exception 'Une réduction accordée à un élève demande un motif' using errcode = '23514';
    end if;
    if t not in ('personnalisee', 'personnel') then
      new.duree_annees := 1; new.annee_rang := 1; new.reconduite_de := null;
    end if;
    -- Reconduction : même règle, l'année suivante de la même durée.
    if new.reconduite_de is not null then
      select * into avant from public.reductions_eleves where id = new.reconduite_de;
      if avant.regle_id is distinct from new.regle_id or avant.annee_rang >= avant.duree_annees then
        raise exception 'Cette réduction ne peut pas être reconduite' using errcode = '23514';
      end if;
      new.duree_annees := avant.duree_annees;
      new.annee_rang := avant.annee_rang + 1;
      new.personnel_id := coalesce(new.personnel_id, avant.personnel_id);
    else
      new.annee_rang := 1;
    end if;
    if t = 'personnel' and new.personnel_id is null then
      raise exception 'Enfant du personnel : indiquez le parent membre du personnel' using errcode = '23514';
    end if;
  else
    new.inscription_id := old.inscription_id;
    new.regle_id := old.regle_id;
    new.accorde_par := old.accorde_par;
    new.personnel_id := old.personnel_id;
    new.duree_annees := old.duree_annees;
    new.annee_rang := old.annee_rang;
    new.reconduite_de := old.reconduite_de;
  end if;
  return new;
end $$;

-- Même calcul que l'app (caisse.dart), avec l'enfant du personnel en deuxième.
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
       (select g.*, 1 as rang, 0::bigint as ordre2 from public.regles_reduction g
        where g.organisation_id = org and g.actif and g.type = 'fratrie' and n >= 2 and g.nb_enfants <= n
        order by g.nb_enfants desc limit 1)
       union all
       (select g.*, case g.type when 'personnel' then 2 when 'paiement_annuel' then 3 else 4 end,
               extract(epoch from g.created_at)::bigint
        from public.regles_reduction g
        join public.reductions_eleves re on re.regle_id = g.id and re.inscription_id = ins and re.actif
        where g.actif and g.type in ('personnel', 'paiement_annuel', 'personnalisee'))
     ) x order by rang, ordre2)
  loop
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
revoke all on function scolagrid.reduction_frais(uuid, text, bigint) from public;

-- Remboursements autorisés de vive voix ------------------------------------------------

alter table public.organisations
  add column delai_confirmation_heures integer not null default 48 check (delai_confirmation_heures between 1 and 720);

alter table public.remboursements
  add column autorisation_orale boolean not null default false,
  add column autorise_oralement_par uuid,       -- fiche du membre de la direction qui a dit oui
  add column confirmation text check (confirmation is null or confirmation in ('attendue', 'confirmee', 'contestee')),
  add column confirme_par uuid references auth.users (id) on delete set null,
  add column confirme_le timestamptz,
  add column motif_contestation text check (motif_contestation is null or length(trim(motif_contestation)) between 3 and 300),
  add constraint remboursements_oral_par
    foreign key (autorise_oralement_par, organisation_id) references public.personnel (id, organisation_id);

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
    new.encaissement_id := l.encaissement_id;
    new.inscription_id := l.inscription_id;
    new.eleve_id := l.eleve_id;
    new.frais_id := l.frais_id;
    new.site_id := l.site_recu;
    new.verse_par := null; new.verse_le := null;
    new.confirme_par := null; new.confirme_le := null; new.motif_contestation := null;
    if connecte then new.demande_par := auth.uid(); end if;
    -- De vive voix : autorisé tout de suite, à confirmer ensuite par la direction.
    if new.autorisation_orale then
      if new.autorise_oralement_par is null then
        raise exception 'Indiquez qui a autorisé le remboursement' using errcode = '23514';
      end if;
      new.statut := 'autorise';
      new.autorise_par := null;
      new.autorise_le := now();
      new.confirmation := 'attendue';
    else
      new.statut := 'demande';
      new.autorise_par := null; new.autorise_le := null;
      new.autorise_oralement_par := null; new.confirmation := null;
    end if;
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
  new.autorisation_orale := old.autorisation_orale; new.autorise_oralement_par := old.autorise_oralement_par;

  -- Confirmation d'une autorisation orale, à toute étape après l'autorisation.
  if old.confirmation = 'attendue' and new.confirmation in ('confirmee', 'contestee') then
    if connecte and not scolagrid.a_le_droit(old.organisation_id, old.site_id, 'valider_remboursement') then
      raise exception 'Confirmer un remboursement demande le droit « valider un remboursement »' using errcode = '42501';
    end if;
    if new.confirmation = 'contestee' and new.motif_contestation is null then
      raise exception 'Une contestation doit être motivée' using errcode = '23514';
    end if;
    if connecte then new.confirme_par := auth.uid(); end if;
    new.confirme_le := now();
    if new.confirmation = 'confirmee' then new.motif_contestation := null; end if;
    -- La confirmation ne touche à rien d'autre.
    new.statut := old.statut; new.beneficiaire := old.beneficiaire; new.mode := old.mode; new.motif_refus := old.motif_refus;
    new.autorise_par := old.autorise_par; new.autorise_le := old.autorise_le;
    new.verse_par := old.verse_par; new.verse_le := old.verse_le; new.decharge := old.decharge;
    return new;
  end if;
  new.confirmation := old.confirmation; new.confirme_par := old.confirme_par;
  new.confirme_le := old.confirme_le; new.motif_contestation := old.motif_contestation;

  if new.statut = old.statut then
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
revoke all on function scolagrid.remboursement_controle() from public;
