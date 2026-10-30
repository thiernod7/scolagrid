import 'package:powersync/powersync.dart';

// Schéma de la base locale. Doit correspondre à serveur/migrations/.
// L'identifiant (id) de chaque table est géré par PowerSync.
const schema = Schema([
  Table('organisations', [
    Column.text('nom'),
    Column.text('ville'),
    Column.text('statut'),
    Column.text('cree_par'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('sites', [
    Column.text('organisation_id'),
    Column.text('nom'),
    Column.text('ville'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ], indexes: [
    Index('par_organisation', [IndexedColumn('organisation_id')]),
  ]),
  Table('rattachements', [
    Column.text('organisation_id'),
    Column.text('site_id'),
    Column.text('user_id'),
    Column.text('role'),
    Column.integer('actif'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('personnes', [
    Column.text('nom_complet'),
    Column.text('telephone'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  // Table de test de la première version.
  Table('hellos', [
    Column.text('message'),
    Column.text('device'),
    Column.text('created_at'),
  ]),
]);
