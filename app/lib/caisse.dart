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
  EcheanceDue(this.libelle, this.montant, this.dateLimite);

  final String libelle;
  final int montant;
  final DateTime dateLimite;
  int paye = 0;

  int get reste => montant - paye;
  bool get soldee => reste <= 0;
  bool enRetard(DateTime aujourdhui) => !soldee && aujourdhui.isAfter(dateLimite);
}

class FraisDu {
  FraisDu({required this.id, required this.libelle, required this.type, required this.total, required this.echeances});

  final String id;
  final String libelle;
  final String type;
  final int total;
  final List<EcheanceDue> echeances;

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
}) {
  final liste = echeances.isEmpty
      ? [EcheanceDue(libelle, total, arrivee)]
      : [for (final e in echeances) EcheanceDue(e.libelle, e.montant, e.dateLimite)];
  // Si les échéances ne font pas exactement le total, la dernière s'ajuste.
  final somme = liste.fold(0, (s, e) => s + e.montant);
  if (somme != total && liste.isNotEmpty) {
    final d = liste.last;
    liste[liste.length - 1] = EcheanceDue(d.libelle, d.montant + total - somme, d.dateLimite);
  }
  var reste = dejaPaye;
  for (final e in liste) {
    final part = reste < e.montant ? reste : e.montant;
    e.paye = part < 0 ? 0 : part;
    reste -= e.paye;
  }
  return FraisDu(id: id, libelle: libelle, type: type, total: total, echeances: liste);
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
