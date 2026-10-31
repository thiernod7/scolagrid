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

/// Étape 3 : crée un code d'invitation pour une fiche du personnel (8 signes,
/// valable 7 jours, usage unique). Le serveur annule les codes précédents.
Future<String> inviterPersonnel(String ficheId) async =>
    await Supabase.instance.client.rpc('inviter_personnel', params: {'fiche': ficheId}) as String;

/// Relie le compte connecté à sa fiche grâce au code reçu.
/// Renvoie l'organisation, ou null si le code est faux ou expiré.
Future<String?> accepterInvitation(String code) async =>
    await Supabase.instance.client.rpc('accepter_invitation', params: {'code_saisi': code}) as String?;

/// Étape 4 : active ce poste. Le serveur lui donne la lettre suivante de
/// l'organisation (A, B, C…), jamais réutilisée. Nécessite le réseau.
Future<({String id, String code})> activerPoste({
  required String organisation,
  required String? site,
  required String nom,
  String? plateforme,
  String? version,
}) async {
  final r = await Supabase.instance.client.rpc('activer_poste', params: {
    'organisation': organisation,
    'site': site,
    'nom': nom,
    'plateforme': plateforme,
    'version_app': version,
  }) as Map<String, dynamic>;
  return (id: r['id'] as String, code: r['code'] as String);
}

/// Enregistre le sigle de l'école, en ligne : il doit être unique sur tout
/// Scolagrid et ne change plus ensuite (il entre dans les matricules).
Future<void> definirSigle(String orgId, String code) =>
    Supabase.instance.client.from('organisations').update({'code': code}).eq('id', orgId);

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
    'affectations': ['actif'],
    'droits_personnel': ['accorde'],
    'eleves_contacts': ['tuteur_principal', 'responsable_financier'],
    'souscriptions': ['actif'],
  };

  static Map<String, dynamic> _pourServeur(String table, Map<String, dynamic> donnees) {
    final copie = {...donnees};
    for (final c in _booleens[table] ?? const <String>[]) {
      final v = copie[c];
      if (v is num) copie[c] = v != 0;
    }
    return copie;
  }

  /// Exécute une écriture ; un refus définitif est abandonné (signalé dans la
  /// console) sans bloquer le reste de la file. Une erreur réseau remonte :
  /// PowerSync réessaiera toute la transaction (les écritures sont rejouables).
  static Future<bool> _essayer(Future<void> Function() ecriture) async {
    try {
      await ecriture();
      return true;
    } on PostgrestException catch (e) {
      if (!_refusDefinitif.hasMatch(e.code ?? '')) rethrow;
      debugPrint('Changement refusé par le serveur, abandonné : ${e.code} ${e.message}');
      return false;
    }
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx == null) return;
    final rest = Supabase.instance.client.rest;
    final ops = tx.crud;
    for (var i = 0; i < ops.length;) {
      final op = ops[i];
      if (op.op == UpdateType.put) {
        // Les créations qui se suivent dans la même table partent ensemble
        // (import de centaines d'élèves : quelques requêtes au lieu de milliers).
        final cles = ([...?op.opData?.keys]..sort()).join(',');
        var j = i + 1;
        while (j < ops.length && j - i < 200 && ops[j].op == UpdateType.put && ops[j].table == op.table &&
            ([...?ops[j].opData?.keys]..sort()).join(',') == cles) {
          j++;
        }
        final lot = [for (final o in ops.sublist(i, j)) _pourServeur(o.table, {...?o.opData, 'id': o.id})];
        final ok = await _essayer(() => rest.from(op.table).upsert(lot));
        if (!ok && lot.length > 1) {
          // Une ligne refusée : on renvoie une par une pour ne perdre que celle-là.
          for (final ligne in lot) {
            await _essayer(() => rest.from(op.table).upsert(ligne));
          }
        }
        i = j;
        continue;
      }
      final table = rest.from(op.table);
      await _essayer(() async {
        if (op.op == UpdateType.patch) {
          await table.update(_pourServeur(op.table, op.opData ?? {})).eq('id', op.id);
        } else {
          await table.delete().eq('id', op.id);
        }
      });
      i++;
    }
    await tx.complete();
  }
}
