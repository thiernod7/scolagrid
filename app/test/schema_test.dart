import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/main.dart';

void main() {
  test('le schéma local contient la table hellos', () {
    expect(schema.tables.map((t) => t.name), contains('hellos'));
  });
}
