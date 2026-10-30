import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/cloud.dart';
import 'package:scolagrid/schema.dart';

void main() {
  test('le schéma local contient les tables de l\'espace école', () {
    final tables = schema.tables.map((t) => t.name);
    for (final t in ['organisations', 'sites', 'rattachements', 'personnes']) {
      expect(tables, contains(t));
    }
  });

  test('les numéros guinéens sont mis au format international', () {
    expect(numeroInternational('620 00 00 01'), '+224620000001');
    expect(numeroInternational('+224 620 00 00 01'), '+224620000001');
    expect(numeroInternational('00224620000001'), '+224620000001');
  });
}
