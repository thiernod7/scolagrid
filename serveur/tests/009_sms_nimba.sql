-- Test de la migration 009 : le crochet d'envoi de SMS.

\set ON_ERROR_STOP on

do $$ begin
  assert scolagrid.numero_local('224620000001') = '620000001', 'Numéro guinéen au format local';
  assert scolagrid.numero_local('+224 620 00 00 01') = '620000001', 'Espaces et + retirés';
  assert scolagrid.numero_local('33612345678') = '33612345678', 'Numéro étranger inchangé';
  -- Sans identifiants NimbaSMS : erreur claire, rien n'est envoyé.
  assert scolagrid.envoyer_sms('{"user": {"phone": "224620000001"}, "sms": {"otp": "123456"}}') -> 'error' ->> 'http_code' = '500',
         'Sans réglages, le crochet signale que le SMS n''est pas configuré';
end $$;

-- Les utilisateurs de l'app ne peuvent ni appeler le crochet ni lire les identifiants.
begin;
set local role authenticated;
do $$ begin
  begin
    perform scolagrid.envoyer_sms('{}');
    raise exception 'Un utilisateur a appelé le crochet SMS';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from scolagrid.reglages;
    raise exception 'Un utilisateur a lu les réglages';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

\echo 'Test 009 : tout est conforme.'
