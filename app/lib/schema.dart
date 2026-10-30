import 'package:powersync/powersync.dart';

// Schéma de la base locale. Doit correspondre à serveur/migrations/.
const schema = Schema([
  Table('hellos', [
    Column.text('message'),
    Column.text('device'),
    Column.text('created_at'),
  ]),
]);
