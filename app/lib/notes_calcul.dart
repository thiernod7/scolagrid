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

/// Traitement de l'absence, au choix de l'école (spécification §5.7) :
/// justifié exclu / non justifié 0 (défaut), toujours 0, toujours exclu.
const traitementsAbsence = {
  'justifie_exclu': 'Absent justifié exclu, non justifié compté 0',
  'toujours_zero': 'Toute absence comptée 0',
  'toujours_exclu': 'Toute absence exclue de la moyenne',
};

/// Ce que vaut une note dans la moyenne : null si elle en est exclue.
double? valeurComptee(NoteCalcul n, {String absences = 'justifie_exclu'}) {
  if (!n.compte) return null;
  return switch (n.etat) {
    'note' => n.valeur,
    'absent' => absences == 'toujours_exclu' ? null : 0,
    'absent_justifie' => absences == 'toujours_zero' ? 0 : null,
    _ => null,
  };
}

/// Moyenne d'une matière (null : aucune note qui compte).
double? moyenneMatiere(Iterable<NoteCalcul> notes, {String absences = 'justifie_exclu'}) {
  var somme = 0.0, poids = 0.0;
  for (final n in notes) {
    final v = valeurComptee(n, absences: absences);
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

/// Un seuil de mention, exprimé dans le barème du cycle (sur 10 au primaire,
/// sur 20 au collège et au lycée) : spécification §8.6.
typedef SeuilMention = ({double minimum, String libelle});

/// Les seuils par défaut dans un barème : 16, 14, 12, 10 sur 20 (8, 7, 6, 5 sur 10),
/// « Insuffisant » en dessous.
List<SeuilMention> mentionsParDefaut(int bareme) => [
      for (final (sur20, libelle) in const [(16.0, 'Très bien'), (14.0, 'Bien'), (12.0, 'Assez bien'), (10.0, 'Passable'), (0.0, 'Insuffisant')])
        (minimum: sur20 * bareme / 20, libelle: libelle),
    ];

/// La mention d'une moyenne : le seuil le plus haut atteint.
String? mentionSelon(double? moyenne, List<SeuilMention> seuils) {
  if (moyenne == null) return null;
  final tries = [...seuils]..sort((a, b) => b.minimum.compareTo(a.minimum));
  for (final s in tries) {
    if (moyenne >= s.minimum - 1e-9) return s.libelle;
  }
  return null;
}

/// Mention avec les seuils par défaut du barème.
String? mention(double? moyenne, int bareme) => mentionSelon(moyenne, mentionsParDefaut(bareme));

/// Maternelle : des acquis, pas des notes (spécification §5.5).
const niveauxAcquis = {
  'acquis': 'Acquis',
  'en_cours': "En cours d'acquisition",
  'non_acquis': 'Non acquis',
};

/// L'acquis retenu pour un domaine sur la période : la dernière observation.
String? acquisRetenu(Iterable<({String date, String? acquis})> observations) {
  String? dernier;
  String? date;
  for (final o in observations) {
    if (o.acquis == null) continue;
    if (date == null || o.date.compareTo(date) >= 0) {
      date = o.date;
      dernier = o.acquis;
    }
  }
  return dernier;
}

/// « 1er », « 2e »…
String rangLisible(int? r) => r == null ? '—' : (r == 1 ? '1er' : '${r}e');
