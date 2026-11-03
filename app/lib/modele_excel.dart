/// Modèle Excel (.xlsx) pour importer les élèves, écrit à la main (le paquet
/// excel ne sait pas faire de listes déroulantes) :
/// - onglet « Élèves » : les titres, une ligne par classe, et des listes
///   déroulantes pour CLASSE, SEXE, TYPE et LIEN ;
/// - onglet « Guide des classes » : comment écrire une classe (tous les niveaux
///   reconnus, séries, lettre du groupe), même si l'école ne l'a pas encore créée ;
/// - onglet « Aide » : quoi écrire dans chaque colonne, avec un exemple ;
/// - onglet « Classes » : les classes de l'école (source de la liste CLASSE).
library;

import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;

import 'import_eleves.dart' show cleClasse;
import 'modele_guineen.dart';

typedef NiveauGuide = ({String nom, String? usage, String? series});

/// Autres écritures comprises à l'import, en plus du nom d'usage.
const _aussiCompris = {
  'Petite section': 'PS',
  'Moyenne section': 'MS',
  'Grande section': 'GS',
  'Terminale': 'Tle, 13ème année',
};

const titresImport = [
  'NOM', 'PRÉNOMS', 'SEXE', 'DATE DE NAISSANCE', 'LIEU DE NAISSANCE', 'CLASSE', 'TYPE', 'PARENT', 'TÉLÉPHONE', 'LIEN',
  "MATRICULE D'ÉTAT", 'ANCIEN MATRICULE', 'QUARTIER',
];

const _largeurs = [18, 24, 8, 20, 20, 22, 16, 24, 18, 16, 20, 20, 20];

/// Nombre de lignes couvertes par les listes déroulantes.
const _lignesMax = 3000;

String _x(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _col(int i) => String.fromCharCode(65 + i); // A à L suffisent ici.

/// [niveauxEcole] : les niveaux déjà dans ScolaGrid (le guide signale ceux qui manquent).
Uint8List modeleExcelPour(List<String> classes, {List<NiveauGuide> niveauxEcole = const []}) {
  final chaines = <String>[];
  final index = <String, int>{};
  int s(String t) => index.putIfAbsent(t, () {
        chaines.add(t);
        return chaines.length - 1;
      });

  /// Une ligne : cellules texte (null = vide), avec un style par cellule.
  String ligne(int r, List<String?> valeurs, {int style = 0, List<int>? styles}) {
    final b = StringBuffer('<row r="$r">');
    for (var i = 0; i < valeurs.length; i++) {
      final v = valeurs[i];
      if (v == null || v.isEmpty) continue;
      final st = styles?[i] ?? style;
      b.write('<c r="${_col(i)}$r" t="s"${st == 0 ? '' : ' s="$st"'}><v>${s(v)}</v></c>');
    }
    b.write('</row>');
    return b.toString();
  }

  String feuille({required String vue, required String colonnes, required String donnees, String fin = ''}) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheetViews>$vue</sheetViews><sheetFormatPr defaultRowHeight="15"/>'
      '<cols>$colonnes</cols><sheetData>$donnees</sheetData>$fin</worksheet>';

  String largeurs(List<int> l, {Map<int, int> styles = const {}}) => [
        for (var i = 0; i < l.length; i++)
          '<col min="${i + 1}" max="${i + 1}" width="${l[i]}" customWidth="1"${styles[i] == null ? '' : ' style="${styles[i]}"'}/>',
      ].join();

  // Bloqué en haut : la ligne des titres reste visible quand on descend.
  const figee = '<sheetView workbookViewId="0"%A%><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
      '<selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView>';

  // Styles : 1 titre (blanc sur bleu), 2 texte (téléphone, matricule gardent leurs zéros),
  // 3 gras, 4 texte à la ligne, 5 grand titre.
  // --- Onglet Élèves.
  final eleves = StringBuffer(ligne(1, titresImport, style: 1));
  for (var i = 0; i < classes.length; i++) {
    eleves.write(ligne(i + 2, [null, null, null, null, null, classes[i]]));
  }
  final n = classes.length + 1;
  // « warning » : Excel prévient mais laisse écrire (une classe pas encore créée, par exemple).
  String liste(String colonne, String formule, String titre, String aide, String erreur, {bool avertir = false}) =>
      '<dataValidation type="list"${avertir ? ' errorStyle="warning"' : ''} allowBlank="1" showInputMessage="1" showErrorMessage="1" '
      'errorTitle="${_x(titre)}" error="${_x(erreur)}" promptTitle="${_x(titre)}" prompt="${_x(aide)}" '
      'sqref="${colonne}2:$colonne$_lignesMax"><formula1>${_x(formule)}</formula1></dataValidation>';
  String conseil(String colonne, String titre, String aide) =>
      '<dataValidation allowBlank="1" showInputMessage="1" promptTitle="${_x(titre)}" prompt="${_x(aide)}" '
      'sqref="${colonne}2:$colonne$_lignesMax"/>';
  final validations = [
    liste('F', 'Classes!\$A\$2:\$A\$${n < 2 ? 2 : n}', 'Classe', 'Choisissez dans la liste. Pour une autre classe, écrivez-la comme dans l\'onglet « Guide des classes ».',
        "Cette classe n'existe pas encore dans ScolaGrid. Continuer quand même ? À l'import, ScolaGrid proposera de la créer.",
        avertir: true),
    liste('C', '"M,F"', 'Sexe', 'M (garçon) ou F (fille).', 'Choisissez M ou F.'),
    liste('G', '"Nouvelle,Réinscription,Transfert"', 'Type', 'Vide = Réinscription.',
        'Choisissez Nouvelle, Réinscription ou Transfert.'),
    liste('J', '"Père,Mère,Oncle,Tante,Grand-parent,Frère ou sœur,Tuteur"', 'Lien', 'Lien du parent avec l\'élève. Vide = Tuteur.',
        'Choisissez dans la liste.'),
    conseil('D', 'Date de naissance', 'Jour/mois/année, par exemple 15/03/2014.'),
    conseil('I', 'Téléphone', 'Numéro du parent, par exemple 620 00 00 00.'),
    conseil('L', 'Ancien matricule', "Celui de votre ancien registre, s'il existe. ScolaGrid attribue le sien et garde celui-ci."),
  ];
  final feuilleEleves = feuille(
    vue: figee.replaceFirst('%A%', ' tabSelected="1"'),
    colonnes: largeurs(_largeurs, styles: {8: 2, 10: 2, 11: 2}),
    donnees: eleves.toString(),
    fin: '<dataValidations count="${validations.length}">${validations.join()}</dataValidations>',
  );

  // --- Onglet Aide.
  final exemple = classes.isEmpty ? '' : classes.first;
  final aide = StringBuffer()
    ..write(ligne(1, ['Comment remplir le fichier'], style: 5))
    ..write(ligne(2, ["1. Remplissez l'onglet « Élèves » : une ligne par élève. Ne modifiez pas la première ligne (les titres)."]))
    ..write(ligne(3, ['2. CLASSE : cliquez sur la case, puis sur la petite flèche, et choisissez la classe dans la liste. '
        "Pour une classe qui n'est pas dans la liste, écrivez-la comme indiqué dans l'onglet « Guide des classes »."]))
    ..write(ligne(4, ['3. Il y a déjà une ligne par classe : écrivez un élève dessus, puis copiez-la pour les élèves suivants.']))
    ..write(ligne(5, ['4. Laissez vide ce que vous ne connaissez pas : la fiche sera complétée plus tard dans ScolaGrid.']))
    ..write(ligne(6, ['5. Enregistrez (format Excel .xlsx), puis dans ScolaGrid : Élèves › ⋯ › Importer.']))
    ..write(ligne(8, ['COLONNE', 'OBLIGATOIRE', 'CE QU\'IL FAUT ÉCRIRE', 'EXEMPLE'], style: 1));
  const lignesAide = [
    ['NOM', 'Oui', 'Nom de famille.', 'DIALLO'],
    ['PRÉNOMS', 'Oui', 'Tous les prénoms.', 'Mamadou Aliou'],
    ['SEXE', 'Non', 'M (garçon) ou F (fille), dans la liste.', 'M'],
    ['DATE DE NAISSANCE', 'Non', 'Jour/mois/année.', '15/03/2014'],
    ['LIEU DE NAISSANCE', 'Non', 'Ville ou préfecture.', 'Labé'],
    ['CLASSE', 'Oui', "Dans la liste. Une autre classe s'écrit comme dans l'onglet « Guide des classes » : niveau, série (lycée), lettre.", '%CLASSE%'],
    ['TYPE', 'Non', 'Nouvelle, Réinscription ou Transfert. Vide = Réinscription.', 'Réinscription'],
    ['PARENT', 'Non', 'Nom du parent ou du tuteur.', 'Fatoumata BAH'],
    ['TÉLÉPHONE', 'Non', 'Numéro du parent. Les élèves avec le même numéro sont reliés en frères et sœurs.', '620 00 00 00'],
    ['LIEN', 'Non', 'Père, Mère, Oncle… dans la liste. Vide = Tuteur.', 'Mère'],
    ["MATRICULE D'ÉTAT", 'Non', 'Matricule national (CEE, BEPC…) s\'il existe.', ''],
    ['ANCIEN MATRICULE', 'Non', "Le matricule de l'élève dans votre ancien registre. ScolaGrid lui donne un nouveau matricule "
        "mais garde l'ancien : on retrouve l'élève en le tapant dans la recherche.", '2023-145'],
    ['QUARTIER', 'Non', "Quartier où habite l'élève.", 'Hamdallaye'],
  ];
  for (var i = 0; i < lignesAide.length; i++) {
    aide.write(ligne(i + 9, [for (final v in lignesAide[i]) v.replaceAll('%CLASSE%', exemple)], styles: [3, 0, 4, 0]));
  }
  aide.write(ligne(lignesAide.length + 10, ['Le matricule ScolaGrid de chaque élève est attribué automatiquement.']));
  final feuilleAide = feuille(
    vue: '<sheetView workbookViewId="0"/>',
    colonnes: largeurs([22, 14, 70, 18]),
    donnees: aide.toString(),
  );

  // --- Onglet Classes.
  final listeClasses = StringBuffer(ligne(1, ["CLASSES DE L'ÉCOLE"], style: 1));
  for (var i = 0; i < classes.length; i++) {
    listeClasses.write(ligne(i + 2, [classes[i]]));
  }
  final feuilleClasses = feuille(
    vue: figee.replaceFirst('%A%', ''),
    colonnes: largeurs([30]),
    donnees: listeClasses.toString(),
  );

  // --- Onglet Guide des classes : tous les niveaux reconnus, et comment les écrire.
  final ecole = {for (final n in niveauxEcole) cleClasse(n.nom)};
  final modele = [for (final c in niveauxParCycle.entries) for (final n in c.value) (cycle: cycles[c.key]!, n: n)];
  // Le jeu d'options du lycée de l'école (type 2 si elle n'a pas encore de lycée).
  final jeu = jeuOptionsDe([for (final n in niveauxEcole) n.series]);
  final options = seriesDuJeu(jeu);
  final o1 = jeuxOptions[jeu]!.keys.first;
  final guide = StringBuffer()
    ..write(ligne(1, ['Comment écrire une classe'], style: 5))
    ..write(ligne(2, ["Écrivez le NIVEAU exactement comme dans la colonne B, puis l'OPTION (lycée seulement), puis la LETTRE du groupe."]))
    ..write(ligne(3, ['Exemples : « 10ème A », « 10ème B », « CM2 A », « 11ème $o1 A », « Terminale ${jeuxOptions[jeu]!.keys.last} B ». '
        "S'il n'y a qu'une classe du niveau, la lettre est facultative : « 9ème ». Au lycée, l'option est obligatoire."]))
    ..write(ligne(4, ["N'inventez pas d'autre nom : « 13ème année » n'existe pas, écrivez « Terminale ». "
        '« 1ère année » est compris comme CP1, « 7e » comme 7ème.']))
    ..write(ligne(5, ["Une classe absente de ScolaGrid sera proposée à la création lors de l'import, si son niveau et ses frais "
        "existent (colonne G). Sinon, la direction ajoute d'abord le niveau et ses frais dans Paramètres."]))
    ..write(ligne(6, ["Options du lycée de l'école (type $jeu) : "
        '${jeuxOptions[jeu]!.entries.map((e) => '${e.key} = ${e.value}').join(' ; ')}. Pas d\'autre option.']))
    ..write(ligne(7, ['CYCLE', 'NIVEAU (à écrire)', 'AUSSI COMPRIS', 'OPTIONS (lycée)', 'EXEMPLES DE CLASSES', 'CLASSES DÉJÀ CRÉÉES',
      'DANS VOTRE ÉCOLE'], style: 1));
  var g = 8;
  String exemples(String nom, String? series) {
    final s = (series ?? '').split(',').where((x) => x.isNotEmpty).toList();
    return s.isEmpty ? '$nom A, $nom B' : '$nom ${s.first} A, $nom ${s.last} B';
  }

  String dejaCreees(String nom) {
    final k = cleClasse(nom);
    return classes.where((c) => cleClasse(c) == k || cleClasse(c).startsWith('$k ')).join(', ');
  }

  for (final m in modele) {
    final n = m.n;
    final aussi = [if (n.usage != n.nom) n.usage, ?_aussiCompris[n.nom]].join(', ');
    guide.write(ligne(g++, [
      m.cycle, n.nom, aussi, n.series == null ? '' : options.replaceAll(',', ', '), exemples(n.nom, n.series == null ? null : options),
      dejaCreees(n.nom),
      ecole.contains(cleClasse(n.nom)) ? 'Oui' : 'Niveau à ajouter dans Paramètres',
    ], styles: [0, 3, 0, 0, 0, 0, 0]));
  }
  // Niveaux propres à l'école, hors modèle guinéen.
  final duModele = {for (final m in modele) cleClasse(m.n.nom)};
  for (final n in niveauxEcole.where((n) => !duModele.contains(cleClasse(n.nom)))) {
    guide.write(ligne(g++, [
      'Autre', n.nom, n.usage != null && n.usage != n.nom ? n.usage : '', n.series?.replaceAll(',', ', ') ?? '',
      exemples(n.nom, n.series), dejaCreees(n.nom), 'Oui',
    ], styles: [0, 3, 0, 0, 0, 0, 0]));
  }
  final feuilleGuide = feuille(
    vue: '<sheetView workbookViewId="0"/>',
    colonnes: largeurs([12, 18, 22, 16, 30, 30, 32]),
    donnees: guide.toString(),
  );

  const onglets = ['Élèves', 'Guide des classes', 'Aide', 'Classes'];
  final fichiers = <String, String>{
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '${[for (var i = 1; i <= onglets.length; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<bookViews><workbookView activeTab="0"/></bookViews><sheets>'
        '${[for (var i = 0; i < onglets.length; i++) '<sheet name="${onglets[i]}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
        '</sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 1; i <= onglets.length; i++) '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>'].join()}'
        '<Relationship Id="rId8" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
        '</Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="4"><font><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
        '<font><b/><sz val="11"/><name val="Calibri"/></font>'
        '<font><b/><sz val="14"/><color rgb="FF1E3A8A"/><name val="Calibri"/></font></fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FF1E3A8A"/><bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'
        '<xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>'
        '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>',
    'xl/worksheets/sheet1.xml': feuilleEleves,
    'xl/worksheets/sheet2.xml': feuilleGuide,
    'xl/worksheets/sheet3.xml': feuilleAide,
    'xl/worksheets/sheet4.xml': feuilleClasses,
  };
  // Les chaînes en dernier : toutes les feuilles les ont déjà remplies.
  fichiers['xl/sharedStrings.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${chaines.length}" uniqueCount="${chaines.length}">'
      '${[for (final c in chaines) '<si><t xml:space="preserve">${_x(c)}</t></si>'].join()}</sst>';

  final archive = Archive();
  for (final f in fichiers.entries) {
    final octets = utf8.encode(f.value);
    archive.addFile(ArchiveFile(f.key, octets.length, octets));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
}
