/// Import d'élèves depuis un tableau (Excel ou CSV) : lecture et contrôle, sans
/// rien écrire. Rien n'est créé avant la confirmation de l'utilisateur.
library;

import 'dart:convert' show utf8;

import 'matricule.dart';

// Fichier CSV --------------------------------------------------------------------

/// Caractères 0x80–0x9F de Windows-1252 (le « ANSI » d'Excel en français) ; le
/// reste de la plage 0x00–0xFF est identique au Latin-1.
const _cp1252 = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
];

/// Texte d'un fichier CSV : UTF-8 (avec ou sans BOM), sinon Windows-1252.
String texteCsv(List<int> octets) {
  var o = octets;
  if (o.length >= 3 && o[0] == 0xEF && o[1] == 0xBB && o[2] == 0xBF) o = o.sublist(3);
  try {
    return utf8.decode(o);
  } on FormatException {
    return String.fromCharCodes([for (final b in o) b >= 0x80 && b <= 0x9F ? _cp1252[b - 0x80] : b]);
  }
}

/// Lignes d'un CSV : séparateur deviné (point-virgule, virgule ou tabulation,
/// d'après la ligne d'en-tête), guillemets et retours à la ligne dans une cellule.
List<List<String?>> lireCsv(List<int> octets) {
  final t = texteCsv(octets);
  final premiere = t.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  int compte(String c) => premiere.split(c).length - 1;
  final sep = [';', ',', '\t'].reduce((a, b) => compte(b) > compte(a) ? b : a);
  final lignes = <List<String?>>[];
  var ligne = <String?>[];
  final cellule = StringBuffer();
  var guillemets = false;
  void finCellule() {
    final v = cellule.toString().trim();
    ligne.add(v.isEmpty ? null : v);
    cellule.clear();
  }

  void finLigne() {
    finCellule();
    if (ligne.any((c) => c != null)) lignes.add(ligne);
    ligne = <String?>[];
  }

  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (guillemets) {
      if (c == '"') {
        if (i + 1 < t.length && t[i + 1] == '"') {
          cellule.write('"');
          i++;
        } else {
          guillemets = false;
        }
      } else {
        cellule.write(c);
      }
    } else if (c == '"') {
      guillemets = true;
    } else if (c == sep) {
      finCellule();
    } else if (c == '\n') {
      finLigne();
    } else if (c != '\r') {
      cellule.write(c);
    }
  }
  if (cellule.isNotEmpty || ligne.isNotEmpty) finLigne();
  return lignes;
}

const _enteteCsv = "NOM;PRÉNOMS;SEXE;DATE DE NAISSANCE;LIEU DE NAISSANCE;CLASSE;TYPE;PARENT;TÉLÉPHONE;LIEN;MATRICULE D'ÉTAT;QUARTIER";

/// Classes du modèle guinéen, pour un modèle sans classes encore créées.
const classesModeleGuineen = [
  'Petite section', 'Moyenne section', 'Grande section', 'CP1', 'CP2', 'CE1', 'CE2', 'CM1', 'CM2',
  '7ème', '8ème', '9ème', '10ème', '11ème', '12ème', 'Terminale',
];

/// Modèle à remplir, en CSV (séparateur point-virgule, comme Excel en français) :
/// une ligne par classe de l'école, la colonne CLASSE déjà remplie. On écrit les
/// élèves à côté, en copiant la ligne autant de fois que nécessaire ; les lignes
/// laissées sans nom sont ignorées à l'import.
String modeleCsvPour(List<String> classes) =>
    '$_enteteCsv\r\n${[for (final c in classes) ';;;;;${c.replaceAll(';', ' ')};;;;;;'].join('\r\n')}\r\n';

/// Clé tolérante d'une classe : « 7ème A », « 7e A », « 7eme a », « 7 ème A » → « 7 A ».
String cleClasse(String s) => nomSimplifie(s)
    // « 7E », « 7EME », « 7 EME » → « 7 » ; mais « CE2 E » (groupe E) reste tel quel.
    .replaceAllMapped(RegExp(r'(\d+)(?:IEME|EME|ERE|RE|E|\s(?:IEME|EME|ERE))\b'), (m) => m[1]!)
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    // Écritures courantes : « CP 1 » → CP1, « Tle » ou « 13ème année » → Terminale, « PS » → Petite section.
    .replaceAllMapped(RegExp(r'^(CP|CE|CM) (\d)\b'), (m) => '${m[1]}${m[2]}')
    .replaceFirst(RegExp(r'^(?:TLE|TERM|13(?: ANNEE)?)(?= |$)'), 'TERMINALE')
    .replaceFirst(RegExp(r'^PS(?= |$)'), 'PETITE SECTION')
    .replaceFirst(RegExp(r'^MS(?= |$)'), 'MOYENNE SECTION')
    .replaceFirst(RegExp(r'^GS(?= |$)'), 'GRANDE SECTION');

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
  // Le matricule du registre d'avant ScolaGrid (une colonne « MATRICULE » tout court, c'est lui).
  'ancien_matricule': ['ANCIEN MATRICULE', 'MATRICULE', 'MATRICULE ECOLE', 'MATRICULE INTERNE', 'ANCIEN MAT', 'N MATRICULE',
    'NO MATRICULE', 'NUMERO MATRICULE'],
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
  required Map<String, String> classes, // nom de la classe dans ScolaGrid → id
  required List<({String nom, String prenoms, DateTime? naissance})> existants,
  // Anciens matricules déjà dans ScolaGrid (en minuscules) → nom de l'élève.
  Map<String, String> anciensMatricules = const {},
}) {
  final anciens = Map<String, String>.of(anciensMatricules);
  if (lignes.isEmpty) return [];
  final cols = lireEntete(lignes.first);
  final r = <LigneImport>[];
  // Classes reconnues avec tolérance ; « CM2 » suffit s'il n'y a qu'une classe de CM2.
  final parCle = <String, String>{for (final e in classes.entries) cleClasse(e.key): e.value};
  String? trouverClasse(String? v) {
    if (v == null) return null;
    final k = cleClasse(v);
    final exacte = parCle[k];
    if (exacte != null) return exacte;
    final debut = parCle.entries.where((e) => e.key.startsWith('$k ')).toList();
    return debut.length == 1 ? debut.single.value : null;
  }

  String possibles(String v) {
    final k = cleClasse(v).split(' ').first;
    final proches = classes.keys.where((c) => cleClasse(c).split(' ').first == k).toList();
    final liste = proches.isNotEmpty ? proches : classes.keys.take(12).toList();
    return liste.isEmpty ? '' : ' — classes possibles : ${liste.join(', ')}${proches.isEmpty && classes.length > 12 ? '…' : ''}';
  }

  for (var i = 1; i < lignes.length; i++) {
    final brut = lignes[i];
    final valeurs = {
      for (final c in cols.entries)
        if (c.value < brut.length && (brut[c.value] ?? '').trim().isNotEmpty) c.key: brut[c.value]!.trim(),
    };
    if (valeurs.isEmpty) continue; // ligne vide
    // Ligne du modèle restée sans élève (seulement la classe, le type) : ignorée.
    if (!valeurs.containsKey('nom') && !valeurs.containsKey('prenoms') && valeurs.keys.every((k) => k == 'classe' || k == 'type')) {
      continue;
    }
    final l = LigneImport(i + 1, valeurs);
    l.naissance = lireDate(valeurs['naissance']);
    l.sexe = _sexe(valeurs['sexe']);
    l.lien = _lien(valeurs['lien']);
    final type = nomSimplifie(valeurs['type'] ?? '');
    l.type = type.startsWith('NOUV') ? 'nouvelle' : (type.startsWith('TRANS') ? 'transfert' : 'reinscription');
    l.classeId = trouverClasse(valeurs['classe']);

    if (l.nom.isEmpty || l.prenoms.isEmpty) {
      l.etat = EtatLigne.rejetee;
      l.remarques.add('nom ou prénoms manquant');
    } else if (l.classeId == null) {
      l.etat = EtatLigne.rejetee;
      l.remarques.add(valeurs['classe'] == null
          ? 'classe manquante'
          : 'classe inconnue : « ${valeurs['classe']} »${possibles(valeurs['classe']!)}');
    } else {
      if (valeurs['naissance'] != null && l.naissance == null) l.remarques.add('date illisible : « ${valeurs['naissance']} »');
      if (l.naissance == null) l.remarques.add('date de naissance à compléter');
      if (l.telephone == null) l.remarques.add('téléphone du parent à compléter');
      if (l.sexe == null) l.remarques.add('sexe à compléter');
      if (l.remarques.isNotEmpty) l.etat = EtatLigne.incomplete;

      // Même ancien matricule qu'un élève connu ou qu'une ligne au-dessus : le même enfant, très probablement.
      final ancien = valeurs['ancien_matricule']?.trim().toLowerCase();
      final deja = ancien == null ? null : anciens[ancien];
      if (deja != null) {
        l.etat = EtatLigne.doublon;
        l.remarques.add('même ancien matricule que $deja');
      } else if (ancien != null) {
        anciens[ancien] = '${l.nom} ${l.prenoms}';
      }

      final autres = [
        if (deja == null) ...existants,
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

// Classes absentes de ScolaGrid -----------------------------------------------------

typedef NiveauImport = ({String id, String nom, String? usage, String? series});

/// Une classe du fichier qui n'existe pas (encore) dans ScolaGrid.
class ClasseAbsente {
  ClasseAbsente(this.saisie);

  /// Telle qu'écrite dans le fichier (première fois rencontrée).
  final String saisie;
  int eleves = 0;

  /// Niveau reconnu (null : niveau absent de ScolaGrid ou nom illisible).
  NiveauImport? niveau;
  String? serie;
  String? lettre;

  /// Niveau reconnu mais classe mal écrite (option manquante ou hors du jeu…).
  String? probleme;

  /// Nom que ScolaGrid lui donnera : « 10ème B », « 11ème SS A ».
  String get nom => [niveau?.nom ?? saisie, ?serie, ?lettre].join(' ');
}

/// Retrouve le niveau, la série et la lettre d'une classe écrite à la main :
/// « 10e B » → 10ème, B ; « 11eme ss a » → 11ème, SS, A ; « 1ère année A » → CP1, A.
/// Null si aucun niveau de l'école ne correspond ; [probleme] dit ce qui cloche sinon.
({NiveauImport niveau, String? serie, String? lettre, String? probleme})? decomposerClasse(String saisie, List<NiveauImport> niveaux) {
  final k = cleClasse(saisie);
  NiveauImport? trouve;
  var cle = '';
  for (final n in niveaux) {
    for (final c in [cleClasse(n.nom), if (n.usage != null) cleClasse(n.usage!)]) {
      if (c.isNotEmpty && (k == c || k.startsWith('$c ')) && c.length > cle.length) {
        trouve = n;
        cle = c;
      }
    }
  }
  if (trouve == null) return null;
  final reste = k.substring(cle.length).trim().split(' ').where((x) => x.isNotEmpty).toList();
  String? serie;
  final series = (trouve.series ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
  if (reste.isNotEmpty) {
    for (final s in series) {
      if (nomSimplifie(s) == reste.first) {
        serie = s;
        reste.removeAt(0);
        break;
      }
    }
  }
  final exemple = [trouve.nom, if (series.isNotEmpty) series.first, 'A'].join(' ');
  String? probleme;
  if (serie == null && reste.isNotEmpty && const {'SM', 'SE', 'SS', 'SL'}.contains(reste.first)) {
    probleme = series.isEmpty
        ? "${trouve.nom} n'a pas d'option : écrivez « ${trouve.nom} A »."
        : "l'option ${reste.first} n'existe pas dans le jeu de l'école (${series.join(', ')}).";
  } else if (serie == null && series.isNotEmpty) {
    probleme = 'au lycée, précisez l\'option (${series.join(', ')}) : « $exemple ».';
  } else if (reste.length > 1 || (reste.length == 1 && reste.single.length > 2)) {
    probleme = 'nom non reconnu : écrivez le niveau${series.isEmpty ? '' : ", l'option"} puis la lettre, par exemple « $exemple ».';
  }
  return (niveau: trouve, serie: serie, lettre: reste.isEmpty ? null : reste.last, probleme: probleme);
}

/// Regroupe les lignes rejetées pour classe inconnue, par classe (avec tolérance).
List<ClasseAbsente> classesAbsentes(List<LigneImport> lignes, List<NiveauImport> niveaux) {
  final r = <String, ClasseAbsente>{};
  for (final l in lignes) {
    final v = l.valeurs['classe'];
    if (l.etat != EtatLigne.rejetee || l.classeId != null || v == null || l.nom.isEmpty || l.prenoms.isEmpty) continue;
    final a = r.putIfAbsent(cleClasse(v), () {
      final c = ClasseAbsente(v);
      final d = decomposerClasse(v, niveaux);
      if (d != null) {
        c
          ..niveau = d.niveau
          ..serie = d.serie
          ..lettre = d.lettre
          ..probleme = d.probleme;
      }
      return c;
    });
    a.eleves++;
  }
  return r.values.toList();
}
