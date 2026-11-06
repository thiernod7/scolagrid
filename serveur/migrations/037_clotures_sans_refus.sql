-- 037 : une clôture de caisse n'est plus refusée pour un écart que le poste ne voyait pas.
--
-- Le poste calcule les espèces attendues ; le serveur les recalcule avec ce qu'il a
-- reçu. S'ils diffèrent (une donnée arrivée d'un autre poste, par exemple), le
-- serveur trouvait un « écart non justifié » et refusait la clôture : le comptage
-- de la personne était perdu sans qu'elle le sache. Désormais la clôture est
-- enregistrée avec ce qui a été compté, et marquée « à vérifier ».

alter table public.clotures_caisse add column a_verifier boolean not null default false;

create or replace function scolagrid.cloture_calculee() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  sorties bigint;
  avant record;
  ecart_client bigint := coalesce(new.ecart, 0);
begin
  if tg_op = 'UPDATE' then
    raise exception 'Une clôture de caisse ne se modifie pas' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext(new.organisation_id::text || new.site_id::text || new.encaisse_par::text || new.jour::text));
  select coalesce(sum(total_gnf) filter (where mode = 'especes'), 0),
         count(*),
         coalesce(sum(total_gnf) filter (where mode <> 'especes'), 0)
    into new.attendu_especes, new.nb_recus, new.total_autres_modes
  from public.encaissements
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and jour_caisse = new.jour and statut = 'valide';
  select coalesce(sum(montant_gnf), 0) into sorties from public.remboursements
  where organisation_id = new.organisation_id and site_id = new.site_id and verse_par = new.encaisse_par
    and verse_le = new.jour and statut = 'verse' and mode = 'especes';
  sorties := sorties + (select coalesce(sum(montant_gnf), 0) from public.depenses
    where organisation_id = new.organisation_id and site_id = new.site_id and sortie_par = new.encaisse_par
      and sortie_le = new.jour and statut = 'sortie');
  select count(*) as n, coalesce(sum(attendu_especes), 0) as attendu, coalesce(sum(nb_recus), 0) as recus,
         coalesce(sum(total_autres_modes), 0) as autres
    into avant
  from public.clotures_caisse
  where organisation_id = new.organisation_id and site_id = new.site_id
    and encaisse_par = new.encaisse_par and jour = new.jour;
  new.rang := avant.n + 1;
  new.attendu_especes := new.attendu_especes - sorties - avant.attendu;
  new.nb_recus := new.nb_recus - avant.recus;
  new.total_autres_modes := new.total_autres_modes - avant.autres;
  if avant.n > 0 and new.nb_recus <= 0 and new.attendu_especes = 0 then
    raise exception 'Rien de nouveau à clôturer depuis la dernière clôture' using errcode = '23505';
  end if;
  new.ecart := new.compte_especes - new.attendu_especes;
  new.a_verifier := false;
  if new.ecart <> 0 and new.justification is null then
    -- Le poste ne voyait pas d'écart : c'est le recalcul du serveur qui en trouve un
    -- (donnée arrivée d'un autre poste…). On garde le comptage, on le signale.
    if ecart_client = 0 then
      new.justification := 'Écart apparu au recalcul du serveur : à vérifier';
      new.a_verifier := true;
    else
      raise exception 'Un écart de caisse doit être justifié' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

