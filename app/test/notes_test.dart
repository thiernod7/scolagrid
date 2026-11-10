import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/notes_calcul.dart';

void main() {
  test('Moyenne de matière : poids des types, absent compte 0, justifié exclu', () {
    // Spécification §6.5 : six évaluations (poids 1) + une composition (poids 2) = 103 / 8.
    final notes = [
      for (final v in [12.0, 14.0, 11.0, 13.0, 15.0, 12.0]) NoteCalcul(valeur: v, etat: 'note', poids: 1),
      const NoteCalcul(valeur: 13, etat: 'note', poids: 2),
    ];
    expect(moyenneMatiere(notes), closeTo(12.875, 1e-9));
    // Une exclusion retire son poids : (12 + 14) / 2, pas / 3.
    expect(
        moyenneMatiere(const [
          NoteCalcul(valeur: 12, etat: 'note', poids: 1),
          NoteCalcul(valeur: 14, etat: 'note', poids: 1),
          NoteCalcul(valeur: null, etat: 'absent_justifie', poids: 1),
        ]),
        13);
    // Absent non justifié : 0.
    expect(
        moyenneMatiere(const [
          NoteCalcul(valeur: 12, etat: 'note', poids: 1),
          NoteCalcul(valeur: null, etat: 'absent', poids: 1),
        ]),
        6);
    // Examen blanc hors moyenne ; aucune note : pas de moyenne.
    expect(moyenneMatiere(const [NoteCalcul(valeur: 20, etat: 'note', poids: 1, compte: false)]), isNull);
  });

  test('Moyenne générale : coefficients, matière sans note exclue', () {
    // Spécification §6.4 : 174,50 / 14.
    expect(moyenneGenerale(const [(13.0, 5.0), (11.5, 3.0), (13.0, 2.0), (14.0, 2.0), (10.5, 2.0), (null, 4.0)]),
        closeTo(12.4642857, 1e-6));
  });

  test('Rangs : ex æquo au même rang, sans moyenne pas de rang', () {
    final r = rangs({'a': 15, 'b': 12, 'c': 15, 'd': null, 'e': 9});
    expect(r, {'a': 1, 'c': 1, 'b': 3, 'e': 4});
    expect(rangLisible(1), '1er');
    expect(noteLisible(12.875), '12,88');
    expect(mention(7, 10), 'Bien');
    expect(mention(4.5, 10), 'Insuffisant');
    expect(mention(16, 20), 'Très bien');
  });

  test('Traitement de l\'absence au choix de l\'école', () {
    const notes = [
      NoteCalcul(valeur: 12, etat: 'note', poids: 1),
      NoteCalcul(valeur: null, etat: 'absent', poids: 1),
      NoteCalcul(valeur: null, etat: 'absent_justifie', poids: 1),
    ];
    expect(moyenneMatiere(notes), 6); // (12 + 0) / 2
    expect(moyenneMatiere(notes, absences: 'toujours_zero'), 4); // (12 + 0 + 0) / 3
    expect(moyenneMatiere(notes, absences: 'toujours_exclu'), 12);
  });

  test('Mentions personnalisées et acquis de maternelle', () {
    final seuils = [(minimum: 15.0, libelle: 'Excellent'), (minimum: 10.0, libelle: 'Admis'), (minimum: 0.0, libelle: 'Faible')];
    expect(mentionSelon(15, seuils), 'Excellent');
    expect(mentionSelon(9.99, seuils), 'Faible');
    expect(acquisRetenu([(date: '2026-10-10', acquis: 'non_acquis'), (date: '2026-11-20', acquis: 'en_cours'), (date: '2026-11-25', acquis: null)]),
        'en_cours');
  });
}
