-- 010 : le nom d'expéditeur NimbaSMS devient facultatif.
-- Sans lui, la demande part sans « sender_name » : NimbaSMS applique son
-- expéditeur par défaut, ou refuse (la réponse reste visible dans net._http_response).

create or replace function scolagrid.envoyer_sms(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  service text := (select valeur from scolagrid.reglages where cle = 'nimba_service_id');
  secret text := (select valeur from scolagrid.reglages where cle = 'nimba_secret_token');
  expediteur text := (select nullif(trim(valeur), '') from scolagrid.reglages where cle = 'nimba_expediteur');
  numero text := scolagrid.numero_local(event -> 'user' ->> 'phone');
  code text := event -> 'sms' ->> 'otp';
  corps jsonb;
begin
  if service is null or secret is null then
    return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'Envoi de SMS non configuré'));
  end if;
  if code is null or numero !~ '^[0-9]{8,15}$' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Numéro invalide'));
  end if;
  corps := jsonb_build_object(
    'to', jsonb_build_array(numero),
    'message', 'Votre code Scolagrid : ' || code || '. Ne le communiquez à personne.');
  if expediteur is not null then
    corps := corps || jsonb_build_object('sender_name', expediteur);
  end if;
  -- Appel asynchrone : la connexion n'attend pas la réponse de NimbaSMS.
  perform net.http_post(
    url := 'https://api.nimbasms.com/v1/messages',
    body := corps,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Basic ' || replace(encode(convert_to(service || ':' || secret, 'UTF8'), 'base64'), E'\n', '')),
    timeout_milliseconds := 10000);
  return '{}'::jsonb;
end $$;

revoke all on function scolagrid.envoyer_sms(jsonb) from public, anon, authenticated;
do $$ begin
  if exists (select from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function scolagrid.envoyer_sms(jsonb) to supabase_auth_admin;
  end if;
end $$;
