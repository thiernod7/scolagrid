-- 040 : la répartition d'un versement de scolarité par tranche, enregistrée avec le reçu.
--
-- Au guichet, le caissier annonce « 1re tranche soldée, 50 000 sur la 2e ».
-- Cette répartition est figée sur la ligne du reçu (comme sur la souche papier) :
-- une réduction, un échéancier aménagé ou un reçu annulé plus tard ne la
-- recalculent pas. Format : [{"tranche": "1re tranche", "echeance": "2026-10-15",
-- "montant": 300000}, …], dans l'ordre des tranches ; la somme fait le montant
-- de la ligne. Vide (null) pour les frais sans tranches.

alter table public.lignes_encaissement add column imputation jsonb;

create or replace function scolagrid.imputation_valide() returns trigger
language plpgsql set search_path = '' as $$
declare somme bigint;
begin
  if new.imputation is null then return new; end if;
  if jsonb_typeof(new.imputation) <> 'array' or jsonb_array_length(new.imputation) = 0 then
    raise exception 'Répartition par tranche illisible' using errcode = '23514';
  end if;
  if exists (select 1 from jsonb_array_elements(new.imputation) x
             where jsonb_typeof(x->'montant') <> 'number' or (x->>'montant')::bigint <= 0
                or coalesce(length(trim(x->>'tranche')), 0) = 0) then
    raise exception 'Répartition par tranche : tranche ou montant manquant' using errcode = '23514';
  end if;
  select sum((x->>'montant')::bigint) into somme from jsonb_array_elements(new.imputation) x;
  if somme <> new.montant_gnf then
    raise exception 'Répartition par tranche : % au lieu de %', somme, new.montant_gnf using errcode = '23514';
  end if;
  return new;
end $$;
create trigger imputation_valide before insert on public.lignes_encaissement
  for each row execute function scolagrid.imputation_valide();

-- Les reçus déjà faits : une seule fois, la répartition telle que l'app la
-- calculait (tranches de l'élève si aménagées, sinon celles du frais, réduites
-- au prorata ; versements dans l'ordre des dates). Ensuite elle ne bouge plus.
create or replace function scolagrid.imputer_tranches() returns void
language plpgsql set search_path = '' as $$
declare
  g record;
  t record;
  v record;
  brut bigint;
  net bigint;
  tranches jsonb;
  bornes bigint[];
  noms text[];
  dates text[];
  n integer;
  somme bigint;
  cumul bigint;
  debut bigint;
  i integer;
  part bigint;
  imp jsonb;
begin
  for g in
    select distinct l.inscription_id, l.frais_id, f.montant_gnf as total
    from public.lignes_encaissement l join public.frais f on f.id = l.frais_id
    where f.type_frais = 'scolarite' and l.imputation is null
  loop
    -- Les tranches de l'élève (aménagées) ou celles du frais.
    noms := '{}'; dates := '{}'; bornes := '{}';
    if exists (select 1 from public.echeances_eleves where inscription_id = g.inscription_id and frais_id = g.frais_id) then
      for t in select libelle, date_limite, montant_gnf from public.echeances_eleves
               where inscription_id = g.inscription_id and frais_id = g.frais_id order by ordre loop
        noms := noms || t.libelle; dates := dates || t.date_limite::text; bornes := bornes || t.montant_gnf;
      end loop;
    else
      brut := g.total;
      net := brut - scolagrid.reduction_frais(g.inscription_id, 'scolarite', brut);
      for t in select libelle, date_limite, montant_gnf from public.echeances where frais_id = g.frais_id order by ordre loop
        noms := noms || t.libelle; dates := dates || t.date_limite::text;
        bornes := bornes || (case when brut = 0 then 0 else floor(t.montant_gnf * net / brut::numeric)::bigint end);
      end loop;
      n := coalesce(array_length(bornes, 1), 0);
      if n > 0 then
        select sum(x) into somme from unnest(bornes) x;
        bornes[n] := bornes[n] + net - somme; -- la dernière s'ajuste, comme dans l'app
      end if;
    end if;
    n := coalesce(array_length(bornes, 1), 0);
    continue when n = 0;
    -- Les versements dans l'ordre : chacun remplit la tranche en cours, puis la suivante.
    cumul := 0;
    for v in
      select li.id, li.montant_gnf from public.lignes_encaissement li
      join public.encaissements e on e.id = li.encaissement_id
      where li.inscription_id = g.inscription_id and li.frais_id = g.frais_id and li.imputation is null
        and e.statut = 'valide'
      order by e.date_effective, e.created_at, li.created_at
    loop
      imp := '[]'; debut := 0;
      for i in 1..n loop
        part := least(cumul + v.montant_gnf, debut + bornes[i]) - greatest(cumul, debut);
        if part > 0 then
          imp := imp || jsonb_build_object('tranche', noms[i], 'echeance', dates[i], 'montant', part);
        end if;
        debut := debut + bornes[i];
      end loop;
      -- Au-delà de la dernière tranche (trop-perçu) : sur la dernière.
      part := (cumul + v.montant_gnf) - greatest(cumul, debut);
      if part > 0 then
        if jsonb_array_length(imp) = 0 then
          imp := jsonb_build_array(jsonb_build_object('tranche', noms[n], 'echeance', dates[n], 'montant', part));
        else
          imp := jsonb_set(imp, array[(jsonb_array_length(imp) - 1)::text, 'montant'],
                           to_jsonb((imp->(jsonb_array_length(imp) - 1)->>'montant')::bigint + part));
        end if;
      end if;
      -- Seule écriture permise sur une ligne figée : sa répartition, une fois.
      perform set_config('scolagrid.imputation', 'oui', true);
      update public.lignes_encaissement set imputation = imp where id = v.id;
      perform set_config('scolagrid.imputation', '', true);
      cumul := cumul + v.montant_gnf;
    end loop;
  end loop;
end $$;
revoke all on function scolagrid.imputer_tranches() from public;

-- La ligne reste figée ; seule la répartition des anciens reçus s'écrit, une fois.
create or replace function scolagrid.ligne_figee() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_setting('scolagrid.imputation', true) = 'oui' and old.imputation is null
     and (to_jsonb(new) - 'imputation' - 'updated_at') = (to_jsonb(old) - 'imputation' - 'updated_at') then
    return new;
  end if;
  raise exception 'Une ligne de reçu ne se modifie pas : annulez le reçu' using errcode = '42501';
end $$;

select scolagrid.imputer_tranches();
