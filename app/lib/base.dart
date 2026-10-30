import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'schema.dart';

/// La base locale du poste : l'app lit et écrit uniquement ici.
late final PowerSyncDatabase db;

Future<void> ouvrirBase() async {
  final dir = await getApplicationSupportDirectory();
  db = PowerSyncDatabase(schema: schema, path: p.join(dir.path, 'scolagrid.db'));
  await db.initialize();
}
