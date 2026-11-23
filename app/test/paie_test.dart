import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/paie_calcul.dart';

void main() {
  test('à l\'heure : ligne par ligne, au taux de chaque cycle', () {
    const lignes = [
      LigneHeures(classe: '7ème A', matiere: 'Maths', cycle: 'college', heuresSemaine: 6, taux: 25000),
      LigneHeures(classe: '8ème A', matiere: 'Maths', cycle: 'college', heuresSemaine: 6, taux: 25000),
      LigneHeures(classe: 'Terminale SM', matiere: 'Maths', cycle: 'lycee', heuresSemaine: 6, taux: 35000),
    ];
    // 24 h par ligne (6 h × 4 semaines) : 600 000 + 600 000 + 840 000.
    expect(montantHeures(lignes), 2040000);
    // 3 heures d'absence en 7ème A : 21 h payées sur cette ligne.
    final corrigees = [lignes[0].avecHeures(21, 'Absence le 12/11'), lignes[1], lignes[2]];
    expect(montantHeures(corrigees), 2040000 - 3 * 25000);
    // Le détail se relit à l'identique.
    final relu = LigneHeures.depuisJson(corrigees[0].versJson());
    expect(relu.heuresPayees, 21);
    expect(relu.motif, 'Absence le 12/11');
    expect(LigneHeures.depuisJson(lignes[1].versJson()).heuresFaites, isNull);
  });

  test('avances : une mensualité par mois, la plus ancienne d\'abord, sous le plafond', () {
    const avances = [
      (id: 'a', montant: 300000, mensualites: 3, date: '2026-10-05'),
      (id: 'b', montant: 100000, mensualites: 1, date: '2026-11-02'),
    ];
    expect(retenueProposee(avances, 0, plafond: 1000000), 200000);
    // Après 250 000 déjà retenus : il reste 50 000 sur a et 100 000 sur b.
    expect(restesAvances(avances, 250000), {'a': 50000, 'b': 100000});
    expect(retenueProposee(avances, 250000, plafond: 1000000), 150000);
    // Le plafond limite la retenue.
    expect(retenueProposee(avances, 0, plafond: 120000), 120000);
    // Tout remboursé : rien.
    expect(retenueProposee(avances, 400000, plafond: 1000000), 0);
  });

  test('le net ne descend jamais sous zéro : la retenue d\'avance s\'ajuste', () {
    expect(netAPayer(salaire: 1500000, heures: 0, primes: 100000, retenues: 50000, retenueAvance: 200000),
        (net: 1350000, retenueAvance: 200000));
    expect(netAPayer(salaire: 100000, heures: 0, primes: 0, retenues: 0, retenueAvance: 300000), (net: 0, retenueAvance: 100000));
  });
}
