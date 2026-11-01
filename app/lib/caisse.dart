/// Calculs de caisse sans écran : ce qu'un élève doit, comment un versement se
/// répartit, numéros de reçu. Testés dans test/schema_test.dart.
library;

const modesPaiement = {
  'especes': 'Espèces',
  'orange_money': 'Orange Money',
  'mtn_money': 'MTN Mobile Money',
  'cheque': 'Chèque',
  'virement': 'Virement',
};

/// Ordre de paiement des types de frais quand le parent « paie ce qu'il peut ».
const ordreTypes = ['inscription', 'reinscription', 'scolarite', 'optionnel'];

class EcheanceDue {
  EcheanceDue(this.libelle, this.montant, this.dateLimite, {this.grace = 0});

  final String libelle;
  final int montant;
  final DateTime dateLimite;

  /// Jours de grâce après la date limite avant de parler de retard.
  final int grace;
  int paye = 0;

  int get reste => montant - paye;
  bool get soldee => reste <= 0;
  bool enRetard(DateTime aujourdhui) => !soldee && aujourdhui.isAfter(dateLimite.add(Duration(days: grace)));
}

/// Nombre de mois entiers entre deux dates (de mois à mois).
int moisEntre(DateTime a, DateTime b) => (b.year - a.year) * 12 + b.month - a.month;

/// Arrivée en cours d'année, « à partir du mois d'arrivée » : ce qu'on retire
/// de la scolarité pour les mois déjà passés. 900 000 sur 9 mois (octobre à
/// juin), arrivée en novembre : 100 000 retirés.
int retraitMoisArrivee({required int total, required DateTime rentree, required DateTime fin, required DateTime arrivee}) {
  final mois = moisEntre(rentree, fin) + 1;
  final passes = moisEntre(rentree, arrivee);
  if (mois <= 0 || passes <= 0) return 0;
  return (total * (passes > mois ? mois : passes) / mois).floor();
}

class FraisDu {
  FraisDu({
    required this.id,
    required this.libelle,
    required this.type,
    required this.total,
    required this.echeances,
    this.reduction = 0,
    this.retrait = 0,
  });

  final String id;
  final String libelle;
  final String type;
  /// Montant dû, réduction déduite.
  final int total;
  final List<EcheanceDue> echeances;
  final int reduction;

  /// Retiré pour une arrivée en cours d'année (mois passés ou montant négocié).
  final int retrait;

  int get brut => total + reduction + retrait;

  int get paye => echeances.fold(0, (s, e) => s + e.paye);
  int get reste => total - paye;
}

/// Construit la situation d'un frais : ses échéances (ou une seule, à la date
/// d'arrivée de l'élève) remplies dans l'ordre par ce qui a été payé.
FraisDu situationFrais({
  required String id,
  required String libelle,
  required String type,
  required int total,
  required List<({String libelle, int montant, DateTime dateLimite})> echeances,
  required DateTime arrivee,
  required int dejaPaye,
  int reduction = 0,
  int retrait = 0,
  int grace = 0,
}) {
  // La réduction se répartit sur les échéances au prorata : 750 000 en 3 tranches,
  // moins 20 %, donne 3 tranches de 200 000.
  final brut = total;
  total = brut - reduction;
  var liste = echeances.isEmpty
      ? [EcheanceDue(libelle, total, arrivee, grace: grace)]
      : [
          for (final e in echeances)
            EcheanceDue(e.libelle, brut == 0 ? 0 : (e.montant * total / brut).floor(), e.dateLimite, grace: grace),
        ];
  // Si les échéances ne font pas exactement le total, la dernière s'ajuste.
  final somme = liste.fold(0, (s, e) => s + e.montant);
  if (somme != total && liste.isNotEmpty) {
    final d = liste.last;
    liste[liste.length - 1] = EcheanceDue(d.libelle, d.montant + total - somme, d.dateLimite, grace: grace);
  }
  // Arrivée en cours d'année : on retire d'abord sur les premières échéances.
  if (retrait > total) retrait = total;
  if (retrait > 0) {
    var aRetirer = retrait;
    liste = [
      for (final e in liste)
        () {
          final moins = aRetirer < e.montant ? aRetirer : e.montant;
          aRetirer -= moins;
          return EcheanceDue(e.libelle, e.montant - moins, e.dateLimite, grace: grace);
        }(),
    ].where((e) => e.montant > 0).toList();
    total -= retrait;
  }
  var reste = dejaPaye;
  for (final e in liste) {
    final part = reste < e.montant ? reste : e.montant;
    e.paye = part < 0 ? 0 : part;
    reste -= e.paye;
  }
  return FraisDu(id: id, libelle: libelle, type: type, total: total, echeances: liste, reduction: reduction, retrait: retrait);
}

/// Répartit un versement sur les frais d'un élève : inscription d'abord, puis
/// scolarité (tranche par tranche), puis le reste. Jamais plus que ce qui est dû.
Map<String, int> repartir(int montant, List<FraisDu> frais) {
  final tries = [...frais]..sort((a, b) => ordreTypes.indexOf(a.type).compareTo(ordreTypes.indexOf(b.type)));
  final r = <String, int>{};
  var reste = montant;
  for (final f in tries) {
    if (reste <= 0) break;
    final part = f.reste < reste ? f.reste : reste;
    if (part > 0) {
      r[f.id] = part;
      reste -= part;
    }
  }
  return r;
}

/// Numéro de reçu suivant pour ce poste : REC-ALPHA-DONKA-2026-B0042.
String numeroRecuSuivant(
    {required String sigle, required String codeSite, required String annee, required String lettre, required Iterable<String> existants}) {
  final prefixe = 'REC-$sigle-$codeSite-${annee.substring(0, 4)}-$lettre';
  var max = 0;
  for (final n in existants) {
    if (!n.startsWith(prefixe)) continue;
    final v = int.tryParse(n.substring(prefixe.length));
    if (v != null && v > max) max = v;
  }
  return '$prefixe${(max + 1).toString().padLeft(4, '0')}';
}

/// Feuille suivante du carnet papier : « 001452 » → « 001453 ».
String? feuilleSuivante(String? derniere) {
  if (derniere == null) return null;
  final m = RegExp(r'^(.*?)(\d+)$').firstMatch(derniere);
  if (m == null) return null;
  final n = int.parse(m[2]!) + 1;
  return '${m[1]}${n.toString().padLeft(m[2]!.length, '0')}';
}

// Réductions --------------------------------------------------------------------
// Même calcul que la fonction serveur scolagrid.reduction_frais (migration 011).

const typesReduction = {
  'fratrie': 'Fratrie (même payeur)',
  'paiement_annuel': "Paiement de l'année en une fois",
  'personnalisee': 'Personnalisée (bourse, orphelin, mérite…)',
};

const porteesReduction = {
  'scolarite': 'Scolarité',
  'inscription': 'Inscription et réinscription',
  'tous': 'Tous les frais',
};

class Regle {
  const Regle({
    required this.id,
    required this.type,
    required this.libelle,
    required this.pourcentage,
    required this.valeur,
    required this.portee,
    this.nbEnfants,
  });

  final String id;
  final String type;
  final String libelle;
  final bool pourcentage;
  final num valeur;
  final String portee;
  final int? nbEnfants;

  bool couvre(String typeFrais) => switch (portee) {
        'scolarite' => typeFrais == 'scolarite',
        'inscription' => typeFrais == 'inscription' || typeFrais == 'reinscription',
        _ => true,
      };

  int montantSur(int total) => pourcentage ? (total * valeur / 100).floor() : (valeur < total ? valeur.toInt() : total);
}

/// Réductions dont l'élève bénéficie : fratrie selon le nombre d'enfants du même
/// payeur (le barème au seuil le plus haut atteint), paiement annuel et
/// réductions personnalisées si elles lui sont attribuées. Sans cumul, une seule :
/// Fratrie, puis Paiement annuel, puis Personnalisée.
List<Regle> reductionsApplicables({
  required List<Regle> regles,
  required Set<String> attribuees,
  required int enfantsDuPayeur,
  required bool cumul,
}) {
  final fratries = regles.where((r) => r.type == 'fratrie' && (r.nbEnfants ?? 2) <= enfantsDuPayeur && enfantsDuPayeur >= 2).toList()
    ..sort((a, b) => (b.nbEnfants ?? 2).compareTo(a.nbEnfants ?? 2));
  final liste = [
    if (fratries.isNotEmpty) fratries.first,
    ...regles.where((r) => r.type == 'paiement_annuel' && attribuees.contains(r.id)),
    ...regles.where((r) => r.type == 'personnalisee' && attribuees.contains(r.id)),
  ];
  return cumul || liste.isEmpty ? liste : [liste.first];
}

/// Montant de réduction sur un frais, plafonné (cumul) et jamais plus que le frais.
int reductionSurFrais({required String typeFrais, required int total, required List<Regle> applicables, required bool cumul, required int plafond}) {
  var r = 0;
  for (final x in applicables.where((x) => x.couvre(typeFrais))) {
    r += x.montantSur(total);
  }
  if (cumul) {
    final max = (total * plafond / 100).floor();
    if (r > max) r = max;
  }
  return r > total ? total : r;
}

// Montant en lettres (décharges, reçus) ------------------------------------------

const _unites = [
  'zéro', 'un', 'deux', 'trois', 'quatre', 'cinq', 'six', 'sept', 'huit', 'neuf', 'dix',
  'onze', 'douze', 'treize', 'quatorze', 'quinze', 'seize', 'dix-sept', 'dix-huit', 'dix-neuf',
];
const _dizaines = ['', '', 'vingt', 'trente', 'quarante', 'cinquante', 'soixante', 'soixante', 'quatre-vingt', 'quatre-vingt'];

String _moinsDeCent(int n) {
  if (n < 20) return _unites[n];
  final d = n ~/ 10;
  var u = n % 10;
  if (d == 7 || d == 9) u += 10; // soixante-dix, quatre-vingt-dix
  final base = _dizaines[d];
  if (u == 0) return d == 8 ? 'quatre-vingts' : base;
  if (u == 1 && d != 8 && d != 9) return '$base et un';
  if (u == 11 && d == 7) return 'soixante et onze';
  return '$base-${_unites[u]}';
}

String _moinsDeMille(int n) {
  final c = n ~/ 100;
  final r = n % 100;
  final cents = c == 0 ? '' : (c == 1 ? 'cent' : '${_unites[c]} cent${r == 0 ? 's' : ''}');
  if (r == 0) return cents;
  return cents.isEmpty ? _moinsDeCent(r) : '$cents ${_moinsDeCent(r)}';
}

/// 1 250 000 → « un million deux cent cinquante mille ».
String enLettres(int n) {
  if (n == 0) return 'zéro';
  final parts = <String>[];
  final milliards = n ~/ 1000000000;
  final millions = (n ~/ 1000000) % 1000;
  final milliers = (n ~/ 1000) % 1000;
  final reste = n % 1000;
  if (milliards > 0) parts.add('${_moinsDeMille(milliards)} milliard${milliards > 1 ? 's' : ''}');
  if (millions > 0) parts.add('${_moinsDeMille(millions)} million${millions > 1 ? 's' : ''}');
  if (milliers > 0) {
    // « mille » est invariable, et « cent » ne prend pas de s devant lui.
    parts.add(milliers == 1 ? 'mille' : '${_moinsDeMille(milliers).replaceAll(RegExp(r'cents$'), 'cent')} mille');
  }
  if (reste > 0) parts.add(_moinsDeMille(reste));
  return parts.join(' ');
}
