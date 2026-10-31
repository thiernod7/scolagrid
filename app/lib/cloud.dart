import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType, PostgrestException, Supabase;

// Renseignés au build par --dart-define. Vides : l'app tourne en local seulement.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');
const environnement = String.fromEnvironment('SCOLAGRID_ENV', defaultValue: 'prod');

bool get cloudConfigured =>
    supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty && powersyncUrl.isNotEmpty;

Future<void> initCloud() =>
    Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);

/// Vrai si une personne est connectée sur ce poste. La session est gardée
/// sur l'appareil : l'app s'ouvre ensuite sans réseau.
bool get estConnecte => cloudConfigured && Supabase.instance.client.auth.currentSession != null;

String? get monId => cloudConfigured ? Supabase.instance.client.auth.currentUser?.id : null;

/// Met un numéro saisi au format international. « 620 00 00 01 » devient
/// « +224620000001 » ; un numéro déjà international est gardé tel quel.
String numeroInternational(String saisi) {
  final chiffres = saisi.replaceAll(RegExp(r'[^0-9]'), '');
  if (saisi.trim().startsWith('+') || chiffres.startsWith('00')) {
    return '+${chiffres.replaceFirst(RegExp(r'^00'), '')}';
  }
  return chiffres.length == 9 ? '+224$chiffres' : '+$chiffres';
}

Future<void> envoyerCode(String telephone) =>
    Supabase.instance.client.auth.signInWithOtp(phone: telephone);

Future<void> verifierCode(String telephone, String code) =>
    Supabase.instance.client.auth.verifyOTP(type: OtpType.sms, phone: telephone, token: code);

/// Vrai si la personne connectée appartient déjà à une organisation.
/// Demande au serveur : appelé juste après la connexion, donc en ligne.
Future<bool> aDejaUnEspace() async {
  final lignes = await Supabase.instance.client.from('rattachements').select('id').limit(1);
  return lignes.isNotEmpty;
}

/// Étape 1 de l'onboarding : le serveur crée l'organisation, le premier site
/// et le rattachement « fondateur ». Nécessite le réseau.
Future<String> creerEspaceEcole({
  required String nomComplet,
  required String nomGroupe,
  required String ville,
  required String nomSite,
}) async {
  final id = await Supabase.instance.client.rpc('creer_espace_ecole', params: {
    'nom_groupe': nomGroupe,
    'ville': ville,
    'nom_site': nomSite,
    'nom_complet': nomComplet,
  });
  return id as String;
}

/// Lance la synchronisation de la personne connectée.
/// Hors ligne, PowerSync réessaie tout seul ; l'app reste utilisable.
Future<void> demarrerSynchro(PowerSyncDatabase db) async {
  if (!estConnecte) return;
  await db.connect(connector: SupabaseConnector());
}

/// Déconnecte la personne et efface les données de ce poste.
Future<void> deconnecter(PowerSyncDatabase db) async {
  await db.disconnectAndClear();
  try {
    await Supabase.instance.client.auth.signOut();
  } catch (_) {
    // Hors ligne : la session locale est effacée quand même.
  }
}

/// Fait le lien entre la base locale et le serveur :
/// PowerSync descend les données, ce connecteur remonte la file d'envoi.
class SupabaseConnector extends PowerSyncBackendConnector {
  // Refus définitifs du serveur (droits, contraintes, format) : réessayer ne
  // servirait à rien et bloquerait toute la file, on abandonne le changement.
  static final _refusDefinitif = RegExp(r'^(22...|23...|42501)$');

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final auth = Supabase.instance.client.auth;
    var session = auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) session = (await auth.refreshSession()).session;
    if (session == null) return null;
    return PowerSyncCredentials(endpoint: powersyncUrl, token: session.accessToken);
  }

  // La base locale stocke les booléens en 0/1 ; le serveur attend true/false.
  static const _booleens = {
    'annees_scolaires': ['en_cours'],
    'rattachements': ['actif'],
  };

  static Map<String, dynamic> _pourServeur(String table, Map<String, dynamic> donnees) {
    final copie = {...donnees};
    for (final c in _booleens[table] ?? const <String>[]) {
      final v = copie[c];
      if (v is num) copie[c] = v != 0;
    }
    return copie;
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx == null) return;
    final rest = Supabase.instance.client.rest;
    try {
      for (final op in tx.crud) {
        final table = rest.from(op.table);
        switch (op.op) {
          case UpdateType.put:
            await table.upsert(_pourServeur(op.table, {...?op.opData, 'id': op.id}));
          case UpdateType.patch:
            await table.update(_pourServeur(op.table, op.opData ?? {})).eq('id', op.id);
          case UpdateType.delete:
            await table.delete().eq('id', op.id);
        }
      }
      await tx.complete();
    } on PostgrestException catch (e) {
      if (_refusDefinitif.hasMatch(e.code ?? '')) {
        debugPrint('Changement refusé par le serveur, abandonné : ${e.code} ${e.message}');
        await tx.complete();
      } else {
        rethrow;
      }
    }
  }
}
