/// Calculs de la paie, sans base ni écran (testés à part : test/paie_test.dart).
///
/// - Au mois : le salaire fixe, quels que soient les jours fériés.
/// - À l'heure : ligne par ligne (une classe, une matière), heures × taux du cycle.
///   Les heures prévues du mois = heures par semaine × 4 ; la direction note les
///   heures réellement enseignées (absence, rattrapage) ; on paie celles-ci.
/// - Avances : retenues mois après mois (montant ÷ mensualités), la plus ancienne
///   d'abord, sans dépasser le plafond (la moitié du brut par défaut).
library;

/// Les semaines comptées dans un mois.
const semainesParMois = 4;

/// Une ligne d'heures : une classe, une matière, au taux de son cycle.
class LigneHeures {
  const LigneHeures({
    required this.classe,
    required this.matiere,
    required this.cycle,
    required this.heuresSemaine,
    required this.taux,
    this.heuresFaites,
    this.motif,
  });

  final String classe;
  final String matiere;
  final String cycle;
  final double heuresSemaine;
  final int taux;

  /// Les heures réellement enseignées (null : les heures prévues).
  final double? heuresFaites;
  final String? motif;

  double get heuresPrevues => heuresSemaine * semainesParMois;
  double get heuresPayees => heuresFaites ?? heuresPrevues;
  int get montant => (heuresPayees * taux).round();

  Map<String, Object?> versJson() => {
        'classe': classe,
        'matiere': matiere,
        'cycle': cycle,
        'heures_semaine': heuresSemaine,
        'prevues': heuresPrevues,
        'faites': heuresPayees,
        'taux': taux,
        'montant': montant,
        if (motif != null && motif!.isNotEmpty) 'motif': motif,
      };

  static LigneHeures depuisJson(Map<String, Object?> j) {
    final prevues = (j['prevues'] as num?)?.toDouble();
    final faites = (j['faites'] as num?)?.toDouble();
    return LigneHeures(
      classe: '${j['classe'] ?? ''}',
      matiere: '${j['matiere'] ?? ''}',
      cycle: '${j['cycle'] ?? ''}',
      heuresSemaine: (j['heures_semaine'] as num?)?.toDouble() ?? 0,
      taux: (j['taux'] as num?)?.toInt() ?? 0,
      heuresFaites: faites == null || faites == prevues ? null : faites,
      motif: j['motif'] as String?,
    );
  }

  LigneHeures avecHeures(double? faites, String? motif) => LigneHeures(
        classe: classe,
        matiere: matiere,
        cycle: cycle,
        heuresSemaine: heuresSemaine,
        taux: taux,
        heuresFaites: faites,
        motif: motif,
      );
}

int montantHeures(Iterable<LigneHeures> lignes) => lignes.fold(0, (s, l) => s + l.montant);

/// Une avance : son montant, ses mensualités, sa date (pour l'ordre).
typedef Avance = ({String id, int montant, int mensualites, String date});

/// Ce qui reste à rembourser de chaque avance, la plus ancienne remboursée d'abord.
Map<String, int> restesAvances(List<Avance> avances, int dejaRetenu) {
  final triees = [...avances]..sort((a, b) => a.date.compareTo(b.date));
  var reste = dejaRetenu;
  final r = <String, int>{};
  for (final a in triees) {
    final pris = reste >= a.montant ? a.montant : reste;
    reste -= pris;
    r[a.id] = a.montant - pris;
  }
  return r;
}

/// La retenue proposée ce mois-ci : une mensualité de chaque avance en cours,
/// sans dépasser ce qui reste ni le plafond.
int retenueProposee(List<Avance> avances, int dejaRetenu, {required int plafond}) {
  final restes = restesAvances(avances, dejaRetenu);
  var total = 0;
  for (final a in avances) {
    final reste = restes[a.id] ?? 0;
    if (reste <= 0) continue;
    final mensualite = (a.montant / a.mensualites).ceil();
    total += mensualite < reste ? mensualite : reste;
  }
  if (plafond < 0) return 0;
  return total > plafond ? plafond : total;
}

/// Le net : salaire + heures + primes − retenues − avance (jamais négatif : l'avance s'ajuste).
({int net, int retenueAvance}) netAPayer({
  required int salaire,
  required int heures,
  required int primes,
  required int retenues,
  required int retenueAvance,
}) {
  final avant = salaire + heures + primes - retenues;
  if (avant <= 0) return (net: 0, retenueAvance: 0);
  final avance = retenueAvance > avant ? avant : retenueAvance;
  return (net: avant - avance, retenueAvance: avance);
}
