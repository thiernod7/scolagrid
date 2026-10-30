import 'dart:async';

import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

// Renseignés au build par --dart-define. Vides : l'app tourne en local seulement.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');

bool get cloudConfigured =>
    supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty && powersyncUrl.isNotEmpty;

Future<void> initCloud() =>
    Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);

/// Ouvre une session (anonyme pour ce test) puis lance la synchronisation.
/// Sans réseau, réessaie toutes les 30 secondes ; l'app reste utilisable.
Future<void> connectCloud(PowerSyncDatabase db) async {
  final auth = Supabase.instance.client.auth;
  while (auth.currentSession == null) {
    try {
      await auth.signInAnonymously();
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 30));
    }
  }
  await db.connect(connector: SupabaseConnector());
}

/// Fait le lien entre la base locale et le cloud :
/// PowerSync descend les données, ce connecteur remonte la file d'envoi.
class SupabaseConnector extends PowerSyncBackendConnector {
  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final auth = Supabase.instance.client.auth;
    var session = auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) session = (await auth.refreshSession()).session;
    if (session == null) return null;
    return PowerSyncCredentials(endpoint: powersyncUrl, token: session.accessToken);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx == null) return;
    final rest = Supabase.instance.client.rest;
    for (final op in tx.crud) {
      final table = rest.from(op.table);
      switch (op.op) {
        case UpdateType.put:
          await table.upsert({...?op.opData, 'id': op.id});
        case UpdateType.patch:
          await table.update(op.opData ?? {}).eq('id', op.id);
        case UpdateType.delete:
          await table.delete().eq('id', op.id);
      }
    }
    await tx.complete();
  }
}
