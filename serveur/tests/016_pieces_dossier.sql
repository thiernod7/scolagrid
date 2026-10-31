-- Test de la migration 016 : pièces du dossier.

\set ON_ERROR_STOP on

begin;
update public.eleves set pieces_dossier = 'acte_naissance,photo'
  where id = 'e0000000-0000-0000-0000-000000000002';
do $$ begin
  assert (select pieces_dossier from public.eleves where id = 'e0000000-0000-0000-0000-000000000002')
    = 'acte_naissance,photo', 'Pièces notées';
  begin
    update public.eleves set pieces_dossier = 'Acte; DROP' where id = 'e0000000-0000-0000-0000-000000000002';
    raise exception 'Liste de pièces mal formée acceptée';
  exception when check_violation then null;
  end;
end $$;
rollback;
