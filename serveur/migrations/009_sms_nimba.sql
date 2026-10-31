-- 009 : envoi des codes de connexion par NimbaSMS (fournisseur guinéen).
--
-- Le service de connexion (Auth) ne connaît pas NimbaSMS : il appelle cette
-- fonction (« crochet » d'envoi de SMS), qui transmet le code à l'API NimbaSMS
-- par pg_net. Les identifiants NimbaSMS sont rangés dans scolagrid.reglages par
-- l'installeur, depuis les secrets GitHub ; aucun rôle de l'API n'y a accès.

do $$ begin
  if exists (select from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
end $$;

create table if not exists scolagrid.reglages (
  cle text primary key,
  valeur text not null
);
revoke all on scolagrid.reglages from public;

-- Le numéro au format local guinéen (9 chiffres), comme dans les exemples NimbaSMS.
create or replace function scolagrid.numero_local(numero text) returns text
language sql immutable set search_path = '' as $$
  select case when n ~ '^224[0-9]{9}$' then substr(n, 4) else n end
  from (select regexp_replace(coalesce(numero, ''), '[^0-9]', '', 'g') as n) x
$$;

create or replace function scolagrid.envoyer_sms(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  service text := (select valeur from scolagrid.reglages where cle = 'nimba_service_id');
  secret text := (select valeur from scolagrid.reglages where cle = 'nimba_secret_token');
  expediteur text := (select valeur from scolagrid.reglages where cle = 'nimba_expediteur');
  numero text := scolagrid.numero_local(event -> 'user' ->> 'phone');
  code text := event -> 'sms' ->> 'otp';
begin
  if service is null or secret is null or expediteur is null then
    return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'Envoi de SMS non configuré'));
  end if;
  if code is null or numero !~ '^[0-9]{8,15}$' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Numéro invalide'));
  end if;
  -- Appel asynchrone : la connexion n'attend pas la réponse de NimbaSMS.
  perform net.http_post(
    url := 'https://api.nimbasms.com/v1/messages',
    body := jsonb_build_object(
      'sender_name', expediteur,
      'to', jsonb_build_array(numero),
      'message', 'Votre code Scolagrid : ' || code || '. Ne le communiquez à personne.'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Basic ' || replace(encode(convert_to(service || ':' || secret, 'UTF8'), 'base64'), E'\n', '')),
    timeout_milliseconds := 10000);
  return '{}'::jsonb;
end $$;

revoke all on function scolagrid.envoyer_sms(jsonb) from public;
do $$ begin
  if exists (select from pg_roles where rolname = 'supabase_auth_admin') then
    grant usage on schema scolagrid to supabase_auth_admin;
    grant execute on function scolagrid.envoyer_sms(jsonb) to supabase_auth_admin;
  end if;
end $$;
revoke execute on function scolagrid.envoyer_sms(jsonb) from anon, authenticated;
