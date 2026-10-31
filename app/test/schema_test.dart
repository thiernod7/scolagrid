import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/cloud.dart';
import 'package:scolagrid/caisse.dart';
import 'package:scolagrid/echeancier.dart';
import 'package:scolagrid/import_eleves.dart';
import 'package:scolagrid/matricule.dart';
import 'package:scolagrid/configuration.dart' show empreintePin, gnf, pinValide;
import 'package:scolagrid/fonctions.dart';
import 'package:scolagrid/modele_guineen.dart';
import 'package:scolagrid/schema.dart';

void main() {
  test('le schéma local contient les tables de l\'espace école', () {
    final tables = schema.tables.map((t) => t.name);
    for (final t in ['organisations', 'sites', 'rattachements', 'personnes', 'annees_scolaires', 'niveaux', 'classes', 'matieres', 'frais', 'personnel', 'affectations', 'droits_personnel', 'postes', 'ce_poste', 'echeances', 'eleves', 'contacts', 'eleves_contacts', 'inscriptions', 'historique_eleves', 'souscriptions', 'encaissements', 'lignes_encaissement']) {
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

  test('droits par défaut des fonctions', () {
    expect(droitsDesFonctions(['enseignant']), {'saisir_notes', 'faire_appel'});
    expect(droitsDesFonctions(['fondateur']), droits.keys.toSet());
    // Fonctions cumulées : les droits s'additionnent.
    expect(droitsDesFonctions(['enseignant', 'surveillant']), containsAll(['saisir_notes', 'justifier_absence']));
    // La paie n'est jamais automatique, sauf pour le fondateur.
    for (final f in fonctions.keys.where((f) => f != 'fondateur')) {
      expect(droitsDesFonctions([f]).intersection({'preparer_paie', 'valider_paie', 'verser_paie'}), isEmpty);
    }
  });

  test("code d'invitation lisible", () {
    expect(codeLisible('K7PQ4XZM'), 'K7PQ-4XZM');
  });

  test('code PIN du poste', () {
    expect(pinValide('1234'), isTrue);
    expect(pinValide('123456'), isTrue);
    expect(pinValide('123'), isFalse);
    expect(pinValide('12a4'), isFalse);
    expect(empreintePin('1234', 'sel'), empreintePin('1234', 'sel'));
    expect(empreintePin('1234', 'sel'), isNot(empreintePin('1235', 'sel')));
    expect(empreintePin('1234', 'sel'), isNot(empreintePin('1234', 'autre')));
    expect(empreintePin('1234', 'sel'), isNot(contains('1234')));
  });

  test('sigles proposés', () {
    expect(codeSuggere('Groupe scolaire Les Palmiers'), 'PALMIERS');
    expect(codeSuggere('Site de Donka'), 'DONKA');
    expect(codeSuggere('École Élite'), 'ELITE');
    expect(codeValide('ALPHA'), isTrue);
    expect(codeValide('AL PHA'), isFalse);
    expect(codeValide('A'), isFalse);
  });

  test('scolarité en tranches', () {
    expect(moisParTranche(9, 3), [3, 3, 3]);
    expect(moisParTranche(9, 2), [5, 4]);
    final t = echeancesEnTranches(total: 750000, premierMois: DateTime(2026, 10), mois: [3, 3, 3]);
    expect(t.map((e) => e.montant), [250000, 250000, 250000]);
    expect(t.map((e) => e.dateLimite), [DateTime(2026, 12, 31), DateTime(2027, 3, 31), DateTime(2027, 6, 30)]);
    expect(t.first.libelle, 'Tranche 1');
    // Le reste de la division va sur la première tranche ; le total est toujours juste.
    final r = echeancesEnTranches(total: 1000000, premierMois: DateTime(2026, 10), mois: [3, 3, 3]);
    expect(r.fold<int>(0, (s, e) => s + e.montant), 1000000);
    expect(r[1].montant, 333000);
  });

  test('scolarité au mois', () {
    final m = echeancesMensuelles(parMois: 83000, premierMois: DateTime(2026, 10), nbMois: 9);
    expect(m.length, 9);
    expect(m.first.libelle, 'Octobre');
    expect(m.last.libelle, 'Juin');
    expect(m.last.dateLimite, DateTime(2027, 6, 30));
  });

  test('matricules', () {
    final p = prefixeMatricule(sigle: 'ALPHA', codeSite: 'DONKA', annee: '2026-2027', lettre: 'B');
    expect(p, 'ALPHA-DONKA-2026-B');
    expect(matriculeSuivant(p, []), 'ALPHA-DONKA-2026-B001');
    expect(matriculeSuivant(p, ['ALPHA-DONKA-2026-B041', 'ALPHA-DONKA-2026-B007', 'ALPHA-DONKA-2026-A099']),
        'ALPHA-DONKA-2026-B042');
    expect(matriculeSuivant(p, ['ALPHA-DONKA-2026-B999']), 'ALPHA-DONKA-2026-B1000');
    // Le serveur accepte ce format.
    expect(RegExp(r'^[A-Z0-9]{2,10}-[A-Z0-9]{2,10}-[0-9]{4}-[A-Z]{1,3}[0-9]{3,6}$').hasMatch('ALPHA-DONKA-2026-B042'), isTrue);
  });

  test('doublons', () {
    final n = DateTime(2014, 3, 15);
    expect(ressemblance(nom: 'DIALLO', prenoms: 'Amadou', naissance: n, autreNom: 'Diallo', autrePrenoms: 'Amadou', autreNaissance: n),
        Alerte.forte);
    expect(ressemblance(nom: 'DIALO', prenoms: 'Amadou', naissance: n, autreNom: 'DIALLO', autrePrenoms: 'Amadou',
        autreNaissance: DateTime(2014, 5, 1)), Alerte.moyenne);
    expect(ressemblance(nom: 'BAH', prenoms: 'Fanta', naissance: n, autreNom: 'DIALLO', autrePrenoms: 'Amadou', autreNaissance: n),
        Alerte.aucune);
    expect(ressemblance(nom: 'BAH', prenoms: 'Fanta', autreNom: 'BAH', autrePrenoms: 'Mariama', memeTuteurEtQuartier: true),
        Alerte.faible);
    expect(nomSimplifie('Aïssatou  Bérété'), 'AISSATOU BERETE');
  });

  test('tranches remplies dans l\'ordre', () {
    final t = [
      (libelle: 'Tranche 1', montant: 250000, dateLimite: DateTime(2026, 12, 31)),
      (libelle: 'Tranche 2', montant: 250000, dateLimite: DateTime(2027, 3, 31)),
      (libelle: 'Tranche 3', montant: 250000, dateLimite: DateTime(2027, 6, 30)),
    ];
    final f = situationFrais(
        id: 'sco', libelle: 'Scolarité', type: 'scolarite', total: 750000, echeances: t, arrivee: DateTime(2026, 10, 1), dejaPaye: 600000);
    expect(f.echeances.map((e) => e.paye), [250000, 250000, 100000]);
    expect(f.reste, 150000);
    expect(f.echeances[2].enRetard(DateTime(2027, 7, 1)), isTrue);
    expect(f.echeances[0].enRetard(DateTime(2027, 7, 1)), isFalse);
    // Un frais sans échéance : dû à l'arrivée de l'élève.
    final ins = situationFrais(
        id: 'ins', libelle: 'Inscription', type: 'inscription', total: 150000, echeances: const [], arrivee: DateTime(2026, 10, 5), dejaPaye: 0);
    expect(ins.echeances.single.dateLimite, DateTime(2026, 10, 5));
  });

  test('versement réparti et plafonné', () {
    final ins = situationFrais(
        id: 'ins', libelle: 'Inscription', type: 'inscription', total: 150000, echeances: const [], arrivee: DateTime(2026, 10, 5), dejaPaye: 50000);
    final sco = situationFrais(
        id: 'sco', libelle: 'Scolarité', type: 'scolarite', total: 750000, echeances: const [], arrivee: DateTime(2026, 10, 5), dejaPaye: 0);
    expect(repartir(300000, [sco, ins]), {'ins': 100000, 'sco': 200000});
    // Jamais plus que le total dû.
    expect(repartir(2000000, [sco, ins]), {'ins': 100000, 'sco': 750000});
  });

  test('numéros de reçu et carnet papier', () {
    expect(numeroRecuSuivant(sigle: 'ALPHA', codeSite: 'DONKA', annee: '2026-2027', lettre: 'B', existants: []),
        'REC-ALPHA-DONKA-2026-B0001');
    expect(numeroRecuSuivant(sigle: 'ALPHA', codeSite: 'DONKA', annee: '2026-2027', lettre: 'B',
        existants: ['REC-ALPHA-DONKA-2026-B0041', 'REC-ALPHA-DONKA-2026-A0099']), 'REC-ALPHA-DONKA-2026-B0042');
    expect(RegExp(r'^REC-[A-Z0-9]{2,10}-[A-Z0-9]{2,10}-[0-9]{4}-[A-Z]{1,3}[0-9]{4,7}$').hasMatch('REC-ALPHA-DONKA-2026-B0042'), isTrue);
    expect(feuilleSuivante('001452'), '001453');
    expect(feuilleSuivante('A-099'), 'A-100');
    expect(feuilleSuivante(null), isNull);
  });

  test('import : contrôle des lignes', () {
    final r = analyserImport(
      lignes: [
        ['Nom', 'Prénoms', 'Sexe', 'Né(e) le', 'Classe', 'Parent', 'Téléphone', 'Type'],
        ['Diallo', 'Amadou', 'M', '15/03/2014', '7ème A', 'Mamadou Diallo', '620 00 00 01', ''],
        ['Bah', 'Fanta', 'F', '', '7EME A', 'Oumar Bah', '', 'Nouvelle'],
        ['Camara', 'Kadiatou', 'F', '01/01/2015', '13ème', '', '', ''],
        ['', 'Sans nom', '', '', '7ème A', '', '', ''],
        ['DIALLO', 'Amadou', 'M', '15/03/2014', '7ème A', '', '620000001', ''],
        [null, null, null, null, null, null, null, null],
        ['Sow', 'Ibrahima', 'G', '41000', '7ème A', 'X Sow', '621000000', ''],
      ],
      classes: {nomSimplifie('7ème A'): 'c7a'},
      existants: const [],
    );
    expect(r.length, 6); // la ligne vide est ignorée
    expect(r[0].etat, EtatLigne.valide);
    expect(r[0].type, 'reinscription');
    expect(r[0].naissance, DateTime(2014, 3, 15));
    expect(r[1].etat, EtatLigne.incomplete);
    expect(r[1].type, 'nouvelle');
    expect(r[1].classeId, 'c7a');
    expect(r[2].etat, EtatLigne.rejetee); // classe inconnue
    expect(r[3].etat, EtatLigne.rejetee); // nom manquant
    expect(r[4].etat, EtatLigne.doublon); // même enfant que la ligne 2
    expect(r[5].sexe, 'M');
    expect(r[5].naissance, DateTime(2012, 4, 1)); // date restée en nombre dans Excel
  });

  test('dates saisies à la main', () {
    expect(lireDate('5/3/2014'), DateTime(2014, 3, 5));
    expect(lireDate('2014-03-05'), DateTime(2014, 3, 5));
    expect(lireDate('31/02/2014'), isNull);
    expect(lireDate('vers 2014'), isNull);
  });
}
