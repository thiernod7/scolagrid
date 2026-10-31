/// Import d'élèves depuis un tableau (Excel) : lecture et contrôle, sans rien
/// écrire. Rien n'est créé avant la confirmation de l'utilisateur.
library;

import 'matricule.dart';

/// Colonnes reconnues (l'en-tête du fichier peut varier un peu).
const colonnesImport = {
  'nom': ['NOM', 'NOM DE FAMILLE'],
  'prenoms': ['PRENOMS', 'PRENOM'],
  'sexe': ['SEXE', 'GENRE'],
  'naissance': ['DATE DE NAISSANCE', 'NE LE', 'NEE LE', 'NE E LE', 'NAISSANCE', 'DATE NAISSANCE'],
  'lieu': ['LIEU DE NAISSANCE', 'LIEU NAISSANCE', 'NE A'],
  'classe': ['CLASSE'],
  'type': ['TYPE', 'ADMISSION', 'TYPE D ADMISSION'],
  'parent': ['PARENT', 'TUTEUR', 'NOM DU PARENT', 'NOM DU TUTEUR', 'PARENT TUTEUR'],
  'telephone': ['TELEPHONE', 'TEL', 'CONTACT', 'TELEPHONE PARENT', 'TEL PARENT', 'TELEPHONE DU PARENT'],
  'lien': ['LIEN', 'LIEN DE PARENTE', 'PARENTE'],
  'matricule_etat': ['MATRICULE ETAT', 'MATRICULE D ETAT', 'MATRICULE NATIONAL'],
  'quartier': ['QUARTIER', 'ADRESSE'],
};

enum EtatLigne { valide, incomplete, doublon, rejetee }

class LigneImport {
  LigneImport(this.numero, this.valeurs);

  /// Numéro de ligne dans le fichier (pour que l'école la retrouve).
  final int numero;
  final Map<String, String> valeurs;
  EtatLigne etat = EtatLigne.valide;
  final List<String> remarques = [];
  String? classeId;
  DateTime? naissance;
  String? sexe;
  String type = 'reinscription';
  String lien = 'tuteur';

  String get nom => (valeurs['nom'] ?? '').trim().toUpperCase();
  String get prenoms => (valeurs['prenoms'] ?? '').trim();
  String? get telephone {
    final t = (valeurs['telephone'] ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    return t.length < 8 ? null : t;
  }
}

/// Date écrite à la main : 15/03/2014, 15-03-2014, 2014-03-15.
DateTime? lireDate(String? texte) {
  final t = (texte ?? '').trim();
  if (t.isEmpty) return null;
  var m = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})').firstMatch(t);
  if (m != null) {
    final d = DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
    return d.month == int.parse(m[2]!) ? d : null;
  }
  m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(t);
  if (m != null) return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  // Date restée en nombre dans Excel (jours depuis le 30/12/1899).
  final n = int.tryParse(t.split('.').first);
  if (n != null && n > 25000 && n < 60000) return DateTime(1899, 12, 30 + n);
  return null;
}

String? _sexe(String? s) {
  final t = nomSimplifie(s ?? '');
  if (t.startsWith('M') || t.startsWith('G')) return 'M';
  if (t.startsWith('F')) return 'F';
  return null;
}

String _lien(String? s) {
  final t = nomSimplifie(s ?? '');
  if (t.startsWith('PERE') || t == 'P') return 'pere';
  if (t.startsWith('MERE')) return 'mere';
  if (t.startsWith('ONCLE')) return 'oncle';
  if (t.startsWith('TANTE')) return 'tante';
  if (t.startsWith('GRAND')) return 'grand_parent';
  if (t.startsWith('FRERE') || t.startsWith('SOEUR')) return 'frere_soeur';
  return 'tuteur';
}

/// Associe les colonnes du fichier à nos champs, d'après la ligne d'en-tête.
Map<String, int> lireEntete(List<String?> entete) {
  final r = <String, int>{};
  for (var i = 0; i < entete.length; i++) {
    final h = nomSimplifie(entete[i] ?? '');
    for (final c in colonnesImport.entries) {
      if (!r.containsKey(c.key) && c.value.contains(h)) r[c.key] = i;
    }
  }
  return r;
}

/// Contrôle les lignes : rejet (nom, prénoms ou classe manquants ou inconnus),
/// incomplètes (acceptées, à compléter : date de naissance, téléphone, sexe),
/// doublons probables (avec un élève existant ou une autre ligne du fichier).
List<LigneImport> analyserImport({
  required List<List<String?>> lignes,
  required Map<String, String> classes, // nom simplifié de la classe → id
  required List<({String nom, String prenoms, DateTime? naissance})> existants,
}) {
  if (lignes.isEmpty) return [];
  final cols = lireEntete(lignes.first);
  final r = <LigneImport>[];
  for (var i = 1; i < lignes.length; i++) {
    final brut = lignes[i];
    final valeurs = {
      for (final c in cols.entries)
        if (c.value < brut.length && (brut[c.value] ?? '').trim().isNotEmpty) c.key: brut[c.value]!.trim(),
    };
    if (valeurs.isEmpty) continue; // ligne vide
    final l = LigneImport(i + 1, valeurs);
    l.naissance = lireDate(valeurs['naissance']);
    l.sexe = _sexe(valeurs['sexe']);
    l.lien = _lien(valeurs['lien']);
    final type = nomSimplifie(valeurs['type'] ?? '');
    l.type = type.startsWith('NOUV') ? 'nouvelle' : (type.startsWith('TRANS') ? 'transfert' : 'reinscription');
    l.classeId = classes[nomSimplifie(valeurs['classe'] ?? '')];

    if (l.nom.isEmpty || l.prenoms.isEmpty) {
      l.etat = EtatLigne.rejetee;
      l.remarques.add('nom ou prénoms manquant');
    } else if (l.classeId == null) {
      l.etat = EtatLigne.rejetee;
      l.remarques.add(valeurs['classe'] == null ? 'classe manquante' : 'classe inconnue : « ${valeurs['classe']} »');
    } else {
      if (valeurs['naissance'] != null && l.naissance == null) l.remarques.add('date illisible : « ${valeurs['naissance']} »');
      if (l.naissance == null) l.remarques.add('date de naissance à compléter');
      if (l.telephone == null) l.remarques.add('téléphone du parent à compléter');
      if (l.sexe == null) l.remarques.add('sexe à compléter');
      if (l.remarques.isNotEmpty) l.etat = EtatLigne.incomplete;

      final autres = [
        ...existants,
        for (final x in r.where((x) => x.etat != EtatLigne.rejetee)) (nom: x.nom, prenoms: x.prenoms, naissance: x.naissance),
      ];
      for (final e in autres) {
        // Tri rapide : ni le nom ni le prénom ne commencent pareil → pas un doublon.
        if (e.nom.isEmpty || e.prenoms.isEmpty) continue;
        if (e.nom[0].toUpperCase() != l.nom[0] && e.prenoms[0].toUpperCase() != l.prenoms[0].toUpperCase()) continue;
        final a = ressemblance(
            nom: l.nom, prenoms: l.prenoms, naissance: l.naissance, autreNom: e.nom, autrePrenoms: e.prenoms, autreNaissance: e.naissance);
        if (a == Alerte.forte || (a == Alerte.moyenne && l.naissance != null && e.naissance != null)) {
          l.etat = EtatLigne.doublon;
          l.remarques.add('ressemble à ${e.nom} ${e.prenoms}');
          break;
        }
      }
    }
    r.add(l);
  }
  return r;
}
