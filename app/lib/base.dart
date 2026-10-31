import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'schema.dart';

/// La base locale du poste : l'app lit et écrit uniquement ici.
/// Dans un navigateur, elle vit dans le stockage du site.
late final PowerSyncDatabase db;

Future<void> ouvrirBase() async {
  final chemin = kIsWeb ? 'scolagrid.db' : p.join((await getApplicationSupportDirectory()).path, 'scolagrid.db');
  db = PowerSyncDatabase(schema: schema, path: chemin);
  await db.initialize();
}
