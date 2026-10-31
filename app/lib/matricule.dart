/// Matricules et recherche d'élèves : calculs sans écran, testés.
library;

/// Préfixe des matricules d'un poste pour une année :
/// sigle-site-année-lettre, ex. ALPHA-DONKA-2026-B.
String prefixeMatricule({required String sigle, required String codeSite, required String annee, required String lettre}) =>
    '$sigle-$codeSite-${annee.substring(0, 4)}-$lettre';

/// Matricule suivant, d'après ceux que ce poste a déjà créés avec ce préfixe.
/// Chaque poste a sa lettre : deux postes hors ligne ne peuvent pas produire le
/// même numéro. ALPHA-DONKA-2026-B042 → ALPHA-DONKA-2026-B043.
String matriculeSuivant(String prefixe, Iterable<String> existants) {
  var max = 0;
  for (final m in existants) {
    if (!m.startsWith(prefixe)) continue;
    final n = int.tryParse(m.substring(prefixe.length));
    if (n != null && n > max) max = n;
  }
  return '$prefixe${(max + 1).toString().padLeft(3, '0')}';
}

/// Nom simplifié pour comparer : majuscules, sans accents, sans ponctuation.
String nomSimplifie(String s) {
  const de = 'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿ';
  const vers = 'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOoooooUUUUuuuuYyy';
  final b = StringBuffer();
  for (final c in s.split('')) {
    final i = de.indexOf(c);
    b.write(i < 0 ? c : vers[i]);
  }
  return b.toString().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Distance d'édition (fautes de frappe) entre deux textes.
int distance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prec = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cour = [i, ...List.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      final cout = a[i - 1] == b[j - 1] ? 0 : 1;
      cour[j] = [prec[j] + 1, cour[j - 1] + 1, prec[j - 1] + cout].reduce((x, y) => x < y ? x : y);
    }
    prec = cour;
  }
  return prec[b.length];
}

enum Alerte { aucune, faible, moyenne, forte }

/// Niveau de ressemblance entre un nouvel élève et un élève existant :
/// forte = même nom, prénoms et date de naissance ; moyenne = noms proches et
/// naissance à moins d'un an ; faible = même tuteur (téléphone) et même quartier.
Alerte ressemblance({
  required String nom,
  required String prenoms,
  DateTime? naissance,
  required String autreNom,
  required String autrePrenoms,
  DateTime? autreNaissance,
  bool memeTuteurEtQuartier = false,
}) {
  final a = nomSimplifie('$nom $prenoms');
  final b = nomSimplifie('$autreNom $autrePrenoms');
  if (a == b && naissance != null && naissance == autreNaissance) return Alerte.forte;
  final proches = distance(a, b) <= (a.length < 12 ? 1 : 2) ||
      (nomSimplifie(nom) == nomSimplifie(autreNom) && nomSimplifie(prenoms).split(' ').first == nomSimplifie(autrePrenoms).split(' ').first);
  final naissanceProche = naissance == null || autreNaissance == null || naissance.difference(autreNaissance).inDays.abs() <= 366;
  if (proches && naissanceProche) return Alerte.moyenne;
  if (memeTuteurEtQuartier) return Alerte.faible;
  return Alerte.aucune;
}
