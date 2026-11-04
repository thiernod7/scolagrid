-- 031 : envoyer l'invitation d'un membre du personnel par SMS (NimbaSMS).
--
-- La direction crée le code comme avant (inviter_personnel) ; le serveur
-- l'envoie au numéro de la fiche, avec le lien de l'application. Trois envois
-- au plus par personne et par jour, pour protéger le crédit SMS de l'école.

alter table public.invitations add column sms_envoye_le timestamptz;

create or replace function public.envoyer_invitation_sms(fiche uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  service text := (select valeur from scolagrid.reglages where cle = 'nimba_service_id');
  secret text := (select valeur from scolagrid.reglages where cle = 'nimba_secret_token');
  expediteur text := (select valeur from scolagrid.reglages where cle = 'nimba_expediteur');
  lien text := (select valeur from scolagrid.reglages where cle = 'app_url');
  p public.personnel;
  ecole text;
  numero text;
  cle_code text;
  message text;
begin
  if service is null or secret is null then
    raise exception 'L''envoi de SMS n''est pas configuré ici : transmettez le code autrement' using errcode = '55000';
  end if;
  select * into p from public.personnel where id = fiche;
  if not found or p.id not in (select scolagrid.personnel_que_je_gere()) then
    raise exception 'Fiche introuvable' using errcode = '42501';
  end if;
  numero := scolagrid.numero_local(p.telephone);
  if numero !~ '^[0-9]{8,15}$' then
    raise exception 'Ajoutez d''abord le numéro de téléphone de cette personne' using errcode = '22023';
  end if;
  if (select count(*) from public.invitations
      where personnel_id = fiche and sms_envoye_le > now() - interval '1 day') >= 3 then
    raise exception 'Déjà trois SMS envoyés à cette personne aujourd''hui : réessayez demain' using errcode = '54000';
  end if;

  cle_code := public.inviter_personnel(fiche);   -- mêmes contrôles (droits, fonction, pas de compte)
  update public.invitations set sms_envoye_le = now() where invitations.code = cle_code;
  select coalesce(nullif(trim(o.code), ''), o.nom) into ecole from public.organisations o where o.id = p.organisation_id;

  message := 'Bonjour ' || coalesce(p.prenoms, split_part(p.nom_complet, ' ', 1)) || ', ' || ecole
    || ' vous invite sur ScolaGrid. Code : ' || substr(cle_code, 1, 4) || '-' || substr(cle_code, 5)
    || ' (valable 7 jours)' || coalesce('. Application : ' || lien, '') || '. Connectez-vous avec ce numéro.';
  perform net.http_post(
    url := 'https://api.nimbasms.com/v1/messages',
    body := jsonb_strip_nulls(jsonb_build_object('sender_name', expediteur, 'to', jsonb_build_array(numero), 'message', message)),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Basic ' || replace(encode(convert_to(service || ':' || secret, 'UTF8'), 'base64'), E'\n', '')),
    timeout_milliseconds := 10000);
  return cle_code;
end $$;

revoke all on function public.envoyer_invitation_sms(uuid) from public, anon;
grant execute on function public.envoyer_invitation_sms(uuid) to authenticated;
