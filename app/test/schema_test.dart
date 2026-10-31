import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/cloud.dart';
import 'package:scolagrid/configuration.dart' show gnf;
import 'package:scolagrid/modele_guineen.dart';
import 'package:scolagrid/schema.dart';

void main() {
  test('le schéma local contient les tables de l\'espace école', () {
    final tables = schema.tables.map((t) => t.name);
    for (final t in ['organisations', 'sites', 'rattachements', 'personnes', 'annees_scolaires', 'niveaux', 'classes', 'matieres', 'frais']) {
      expect(tables, contains(t));
    }
  });

  test('les numéros guinéens sont mis au format international', () {
    expect(numeroInternational('620 00 00 01'), '+224620000001');
    expect(numeroInternational('+224 620 00 00 01'), '+224620000001');
    expect(numeroInternational('00224620000001'), '+224620000001');
  });

  test('montants en francs guinéens', () {
    expect(gnf(150000), '150 000 GNF');
    expect(gnf(1250000), '1 250 000 GNF');
    expect(gnf(0), '0 GNF');
  });

  test('année scolaire selon la date', () {
    expect(anneeScolairePour(DateTime(2026, 10, 30)), '2026-2027');
    expect(anneeScolairePour(DateTime(2027, 3, 1)), '2026-2027');
  });

  test('le modèle guinéen couvre tous les cycles', () {
    expect(niveauxParCycle.keys, containsAll(cycles.keys));
    expect(niveauxParCycle['college']!.map((n) => n.nom), contains('10ème'));
  });
}
