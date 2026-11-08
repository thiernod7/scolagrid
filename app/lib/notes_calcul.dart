/// Calcul des moyennes et des rangs (spécification « Notes & bulletins » §6).
///
/// - Moyenne d'une matière sur la période : TOUTES ses notes, pondérées par le
///   poids de leur type (composition ×2), jamais des moyennes intermédiaires.
/// - Une note exclue (absent justifié, dispensé, non concerné, non noté) sort
///   du calcul avec son poids ; un absent non justifié compte 0.
/// - Un type qui ne compte pas (examen blanc) n'entre pas dans la moyenne.
/// - Moyenne générale : moyennes de matières pondérées par leur coefficient ;
///   une matière sans note sort du calcul, coefficient compris.
/// - Aucun arrondi intermédiaire ; deux décimales à l'affichage.
library;

class NoteCalcul {
  const NoteCalcul({required this.valeur, required this.etat, required this.poids, this.compte = true});

  final double? valeur;
  final String etat;
  final double poids;
  final bool compte;
}

/// Ce que vaut une note dans la moyenne : null si elle en est exclue.
double? valeurComptee(NoteCalcul n) {
  if (!n.compte) return null;
  return switch (n.etat) {
    'note' => n.valeur,
    'absent' => 0,
    _ => null,
  };
}

/// Moyenne d'une matière (null : aucune note qui compte).
double? moyenneMatiere(Iterable<NoteCalcul> notes) {
  var somme = 0.0, poids = 0.0;
  for (final n in notes) {
    final v = valeurComptee(n);
    if (v == null) continue;
    somme += v * n.poids;
    poids += n.poids;
  }
  return poids == 0 ? null : somme / poids;
}

/// Moyenne générale à partir des (moyenne, coefficient) des matières.
double? moyenneGenerale(Iterable<(double?, double)> matieres) {
  var somme = 0.0, coef = 0.0;
  for (final (m, c) in matieres) {
    if (m == null || c <= 0) continue;
    somme += m * c;
    coef += c;
  }
  return coef == 0 ? null : somme / coef;
}

/// Rangs (1 = la meilleure moyenne) ; les ex æquo partagent le même rang.
/// Les élèves sans moyenne n'ont pas de rang.
Map<String, int> rangs(Map<String, double?> moyennes) {
  final classes = moyennes.entries.where((e) => e.value != null).toList()
    ..sort((a, b) => b.value!.compareTo(a.value!));
  final r = <String, int>{};
  for (var i = 0; i < classes.length; i++) {
    final egal = i > 0 && (classes[i].value! - classes[i - 1].value!).abs() < 1e-9;
    r[classes[i].key] = egal ? r[classes[i - 1].key]! : i + 1;
  }
  return r;
}

/// « 12,46 » : deux décimales, virgule.
String noteLisible(double? v) => v == null ? '—' : v.toStringAsFixed(2).replaceAll('.', ',');

/// Mention d'après la moyenne ramenée sur 20.
String? mention(double? moyenne, int bareme) {
  if (moyenne == null) return null;
  final sur20 = moyenne * 20 / bareme;
  if (sur20 >= 16) return 'Très bien';
  if (sur20 >= 14) return 'Bien';
  if (sur20 >= 12) return 'Assez bien';
  if (sur20 >= 10) return 'Passable';
  return null;
}

/// « 1er », « 2e »…
String rangLisible(int? r) => r == null ? '—' : (r == 1 ? '1er' : '${r}e');
