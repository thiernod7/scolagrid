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
  // Configuration de l'établissement (étape 2).
  Table('annees_scolaires', [
    Column.text('organisation_id'),
    Column.text('libelle'),
    Column.text('debut'),
    Column.text('fin'),
    Column.integer('en_cours'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('niveaux', [
    Column.text('organisation_id'),
    Column.text('cycle'),
    Column.text('nom'),
    Column.integer('ordre'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  Table('classes', [
    Column.text('organisation_id'),
    Column.text('site_id'),
    Column.text('annee_id'),
    Column.text('niveau_id'),
    Column.text('nom'),
    Column.text('salle'),
    Column.integer('capacite'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ], indexes: [
    Index('par_site', [IndexedColumn('site_id')]),
  ]),
  Table('matieres', [
    Column.text('organisation_id'),
    Column.text('niveau_id'),
    Column.text('nom'),
    Column.real('coefficient'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ], indexes: [
    Index('par_niveau', [IndexedColumn('niveau_id')]),
  ]),
  Table('frais', [
    Column.text('organisation_id'),
    Column.text('annee_id'),
    Column.text('site_id'),
    Column.text('niveau_id'),
    Column.text('libelle'),
    Column.integer('montant_gnf'),
    Column.text('periodicite'),
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
