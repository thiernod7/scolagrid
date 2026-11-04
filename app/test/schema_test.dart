import 'dart:convert' show utf8;
import 'dart:io' show File;

import 'package:excel/excel.dart' as xl;
import 'package:flutter_test/flutter_test.dart';
import 'package:scolagrid/cloud.dart';
import 'package:scolagrid/caisse.dart';
import 'package:scolagrid/echeancier.dart';
import 'package:scolagrid/import_eleves.dart';
import 'package:scolagrid/matricule.dart';
import 'package:scolagrid/configuration.dart' show versionApp, decalerDate, empreintePin, gnf, lettresSuivantes, libelleSuivant, nomDeClasse, pinValide;
import 'package:scolagrid/fonctions.dart';
import 'package:scolagrid/modele_excel.dart';
import 'package:scolagrid/modele_guineen.dart';
import 'package:flutter/material.dart' show Brightness;
import 'package:scolagrid/schema.dart';
import 'package:scolagrid/theme.dart';

void main() {
  test("La version affichée dans l'app est celle de pubspec.yaml", () {
    final v = RegExp(r'^version: ([0-9.]+)\+', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())![1];
    expect(versionApp, v);
  });

  test('le schéma local contient les tables de l\'espace école', () {
    final tables = schema.tables.map((t) => t.name);
    for (final t in ['organisations', 'sites', 'rattachements', 'personnes', 'annees_scolaires', 'niveaux', 'classes', 'matieres', 'frais', 'personnel', 'affectations', 'droits_personnel', 'postes', 'ce_poste', 'echeances', 'eleves', 'contacts', 'eleves_contacts', 'inscriptions', 'historique_eleves', 'souscriptions', 'encaissements', 'lignes_encaissement', 'regles_reduction', 'reductions_eleves', 'clotures_caisse', 'impressions_documents', 'remboursements', 'photos_eleves']) {
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

  test('arrivée en cours d\'année et délai de grâce', () {
    // 900 000 sur 9 mois (octobre à juin), arrivée en novembre : 100 000 retirés.
    expect(retraitMoisArrivee(total: 900000, rentree: DateTime(2026, 10, 1), fin: DateTime(2027, 6, 30), arrivee: DateTime(2026, 11, 4)),
        100000);
    expect(retraitMoisArrivee(total: 900000, rentree: DateTime(2026, 10, 1), fin: DateTime(2027, 6, 30), arrivee: DateTime(2026, 10, 20)), 0);
    final t = [
      (libelle: 'Tranche 1', montant: 300000, dateLimite: DateTime(2026, 10, 15)),
      (libelle: 'Tranche 2', montant: 300000, dateLimite: DateTime(2027, 1, 15)),
      (libelle: 'Tranche 3', montant: 300000, dateLimite: DateTime(2027, 4, 15)),
    ];
    // Montant négocié : 850 000, soit 50 000 retirés sur la première tranche.
    final f = situationFrais(
        id: 'sco', libelle: 'Scolarité', type: 'scolarite', total: 900000, echeances: t, arrivee: DateTime(2026, 11, 4),
        dejaPaye: 0, retrait: 50000, grace: 7);
    expect(f.total, 850000);
    expect(f.echeances.map((e) => e.montant), [250000, 300000, 300000]);
    expect(f.brut, 900000);
    // Grâce de 7 jours : pas en retard le 20 janvier, en retard le 23.
    expect(f.echeances[1].enRetard(DateTime(2027, 1, 20)), isFalse);
    expect(f.echeances[1].enRetard(DateTime(2027, 1, 23)), isTrue);
    // Un retrait plus grand qu'une tranche passe sur la suivante.
    final g = situationFrais(
        id: 'sco', libelle: 'Scolarité', type: 'scolarite', total: 900000, echeances: t, arrivee: DateTime(2027, 2, 1),
        dejaPaye: 0, retrait: 400000);
    expect(g.echeances.map((e) => e.montant), [200000, 300000]);
  });

  test('calendrier de l\'école et frais le plus précis', () {
    final cal = calendrierPropose(periodicite: 'tranches', rentree: DateTime(2026, 10, 1), nbMois: 9);
    expect(cal.map((t) => t.libelle), ['Tranche 1', 'Tranche 2', 'Tranche 3']);
    expect(cal.last.dateLimite, DateTime(2027, 6, 30));
    final e = echeancesDuCalendrier(total: 1000000, calendrier: cal);
    expect(e.map((x) => x.montant), [333333, 333333, 333334]);
    expect(calendrierPropose(periodicite: 'mensuelle', rentree: DateTime(2026, 10, 1), nbMois: 9).length, 9);
    final retenus = fraisRetenus([
      {'type_frais': 'scolarite', 'niveau_id': null, 'site_id': null, 'libelle': 'tous'},
      {'type_frais': 'scolarite', 'niveau_id': 'n7', 'site_id': null, 'libelle': '7ème'},
      {'type_frais': 'inscription', 'niveau_id': null, 'site_id': null, 'libelle': 'ins'},
      {'type_frais': 'optionnel', 'niveau_id': null, 'site_id': null, 'libelle': 'cantine'},
    ]);
    expect(retenus.map((f) => f['libelle']), ['7ème', 'ins', 'cantine']);
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

  test('réductions : mêmes règles que le serveur', () {
    const fratrie2 = Regle(id: 'f2', type: 'fratrie', libelle: '2 enfants', pourcentage: true, valeur: 10, portee: 'scolarite', nbEnfants: 2);
    const fratrie3 = Regle(id: 'f3', type: 'fratrie', libelle: '3 enfants', pourcentage: true, valeur: 15, portee: 'scolarite', nbEnfants: 3);
    const orphelin = Regle(id: 'o', type: 'personnalisee', libelle: 'Orphelin', pourcentage: true, valeur: 100, portee: 'inscription');
    const annuel = Regle(id: 'a', type: 'paiement_annuel', libelle: 'Annuel', pourcentage: true, valeur: 5, portee: 'scolarite');
    final regles = [fratrie2, fratrie3, orphelin, annuel];
    // Fratrie : le seuil le plus haut atteint.
    expect(reductionsApplicables(regles: regles, attribuees: {}, enfantsDuPayeur: 4, cumul: false).single.id, 'f3');
    expect(reductionsApplicables(regles: regles, attribuees: {}, enfantsDuPayeur: 1, cumul: false), isEmpty);
    // Sans cumul : la fratrie passe avant tout le reste.
    final seule = reductionsApplicables(regles: regles, attribuees: {'o', 'a'}, enfantsDuPayeur: 2, cumul: false);
    expect(seule.map((r) => r.id), ['f2']);
    expect(reductionSurFrais(typeFrais: 'inscription', total: 150000, applicables: seule, cumul: false, plafond: 100), 0);
    // Avec cumul : tout s'additionne, dans la limite du plafond.
    final toutes = reductionsApplicables(regles: regles, attribuees: {'o', 'a'}, enfantsDuPayeur: 2, cumul: true);
    expect(reductionSurFrais(typeFrais: 'scolarite', total: 750000, applicables: toutes, cumul: true, plafond: 100), 112500);
    expect(reductionSurFrais(typeFrais: 'scolarite', total: 750000, applicables: toutes, cumul: true, plafond: 12), 90000);
    expect(reductionSurFrais(typeFrais: 'inscription', total: 150000, applicables: toutes, cumul: true, plafond: 100), 150000);
    // La réduction se répartit sur les tranches : 750 000 - 20 % = 3 × 200 000.
    final f = situationFrais(id: 'sco', libelle: 'Scolarité', type: 'scolarite', total: 750000, reduction: 150000, dejaPaye: 0,
        arrivee: DateTime(2026, 10, 1), echeances: [
          (libelle: 'Tranche 1', montant: 250000, dateLimite: DateTime(2026, 12, 31)),
          (libelle: 'Tranche 2', montant: 250000, dateLimite: DateTime(2027, 3, 31)),
          (libelle: 'Tranche 3', montant: 250000, dateLimite: DateTime(2027, 6, 30)),
        ]);
    expect(f.echeances.map((e) => e.montant), [200000, 200000, 200000]);
    expect(f.total, 600000);
    expect(f.brut, 750000);
  });

  test('charte : thèmes clair et sombre', () {
    final clair = themeScolagrid(Brightness.light);
    expect(clair.colorScheme.primary, Couleurs.primaire);
    expect(themeScolagrid(Brightness.dark).brightness, Brightness.dark);
  });

  test('montant en lettres', () {
    expect(enLettres(0), 'zéro');
    expect(enLettres(21), 'vingt et un');
    expect(enLettres(71), 'soixante et onze');
    expect(enLettres(80), 'quatre-vingts');
    expect(enLettres(95), 'quatre-vingt-quinze');
    expect(enLettres(200), 'deux cents');
    expect(enLettres(250000), 'deux cent cinquante mille');
    expect(enLettres(200000), 'deux cent mille');
    expect(enLettres(1000), 'mille');
    expect(enLettres(1250000), 'un million deux cent cinquante mille');
    expect(enLettres(2000000), 'deux millions');
  });

  test('Classes : nom construit et lettres suivantes', () {
    expect(nomDeClasse('7ème', null, 'A'), '7ème A');
    expect(nomDeClasse('Terminale', 'SM', 'B'), 'Terminale SM B');
    expect(lettresSuivantes(['A', null, 'C'], 3), ['B', 'D', 'E']);
    expect(lettresSuivantes(const [], 1), ['A']);
  });

  test('Modèle guinéen : noms d\'usage, examens, séries', () {
    final tous = niveauxParCycle.values.expand((l) => l).toList();
    expect(tous.firstWhere((n) => n.nom == 'CP1').usage, '1ère année');
    expect(tous.where((n) => n.examen != null).map((n) => n.examen), ['CEE', 'BEPC', 'BAC']);
    expect(tous.firstWhere((n) => n.nom == 'Terminale').series, 'SM,SS,SE');
    // Mêmes valeurs que les contrôles du serveur (migration 022).
    expect(examens.keys, ['CEE', 'BEPC', 'BAC']);
    expect(seriesDuJeu(1), 'SS,SL');
    expect(seriesDuJeu(2), 'SM,SS,SE');
    expect(jeuOptionsDe(['SS,SL', null]), 1);
    expect(jeuOptionsDe(['SM,SS,SE']), 2);
    expect(libelleSerie('SS', 1), 'SS — Série scientifique');
    expect(libelleSerie('SS', 2), 'SS — Sciences sociales');
  });

  test("Réductions : l'enfant du personnel passe après la fratrie, avant le paiement annuel", () {
    const regles = [
      Regle(id: 'f', type: 'fratrie', libelle: 'Fratrie', pourcentage: true, valeur: 10, portee: 'scolarite', nbEnfants: 2),
      Regle(id: 'a', type: 'paiement_annuel', libelle: 'Annuel', pourcentage: true, valeur: 5, portee: 'scolarite'),
      Regle(id: 'p', type: 'personnel', libelle: 'Personnel', pourcentage: true, valeur: 50, portee: 'tous'),
    ];
    expect(reductionsApplicables(regles: regles, attribuees: {'a', 'p'}, enfantsDuPayeur: 1, cumul: false).single.id, 'p');
    expect(reductionsApplicables(regles: regles, attribuees: {'a', 'p'}, enfantsDuPayeur: 2, cumul: false).single.id, 'f');
    expect(reductionsApplicables(regles: regles, attribuees: {'a', 'p'}, enfantsDuPayeur: 2, cumul: true).map((r) => r.id), ['f', 'p', 'a']);
    expect(typesReduction.keys, containsAll(['fratrie', 'personnel', 'paiement_annuel', 'personnalisee']));
  });

  test("Année suivante : libellé et dates décalées", () {
    expect(libelleSuivant('2026-2027'), '2027-2028');
    expect(libelleSuivant('Année A'), '');
    expect(decalerDate('2026-10-31', 364), '2027-10-30');
    expect(decalerDate('2027-02-28', 366), '2028-02-29');
  });

  test('Tranches en mois : 4, 3 et 2 mois à partir d\'octobre', () {
    final t = tranchesParMois(rentree: DateTime(2026, 10, 1), mois: [4, 3, 2], noms: ['Première', '', 'Dernière']);
    expect(t.map((x) => x.libelle), ['Première', 'Tranche 2', 'Dernière']);
    expect(t.map((x) => x.dateLimite), [DateTime(2027, 1, 31), DateTime(2027, 4, 30), DateTime(2027, 6, 30)]);
    expect(t.first.part, closeTo(44.44, .01));
    final e = echeancesDuCalendrier(total: 900000, calendrier: t);
    expect(e.map((x) => x.montant), [400000, 300000, 200000]);
  });
  group('Import CSV', () {
    test('Excel en français : points-virgules et accents en ANSI (Windows-1252)', () {
      // En-tête PRÉNOMS (É = 0xC9) et « Aïssatou » (ï = 0xEF), en Windows-1252.
      final octets = [
        ...'NOM;PR'.codeUnits, 0xC9, ...'NOMS;SEXE;CLASSE\r\n'.codeUnits,
        ...'DIALLO;A'.codeUnits, 0xEF, ...'ssatou;F;CE2 A\r\n'.codeUnits,
      ];
      final l = lireCsv(octets);
      expect(l.first, ['NOM', 'PRÉNOMS', 'SEXE', 'CLASSE']);
      expect(l[1], ['DIALLO', 'Aïssatou', 'F', 'CE2 A']);
    });

    test('UTF-8 avec BOM, virgules, guillemets et retour à la ligne dans une cellule', () {
      const texte = 'NOM,PRÉNOMS,CLASSE,QUARTIER\n"BAH","Mamadou ""Bobo""",7ème A,"Kaloum,\nrue 5"\n\n';
      final l = lireCsv([0xEF, 0xBB, 0xBF, ...utf8.encode(texte)]);
      expect(l.length, 2);
      expect(l[1], ['BAH', 'Mamadou "Bobo"', '7ème A', 'Kaloum,\nrue 5']);
    });

    test("Modèle de l'école : lignes sans élève ignorées, classes reconnues avec tolérance", () {
      final classes = {'7ème A': 'c7a', '7ème B': 'c7b', 'CM2 A': 'ccm2', 'CE2 E': 'ce2e'};
      final modele = lireCsv(utf8.encode(modeleCsvPour(classes.keys.toList())));
      expect(analyserImport(lignes: modele, classes: classes, existants: const []), isEmpty);
      const rempli = 'NOM;PRÉNOMS;CLASSE\nDIALLO;Awa;7e a\nBAH;Ali;7eme B\nSOW;Fanta;CM2\nBARRY;Ousmane;CE2 E\nCAMARA;Saran;7ème C\n';
      final r = analyserImport(lignes: lireCsv(utf8.encode(rempli)), classes: classes, existants: const []);
      expect(r.map((x) => x.classeId), ['c7a', 'c7b', 'ccm2', 'ce2e', null]);
      expect(r.last.etat, EtatLigne.rejetee);
      expect(r.last.remarques.single, contains('classes possibles : 7ème A, 7ème B'));
      expect(cleClasse('1ère année'), '1 ANNEE');
      expect(['Tle SM A', '13ème année SM A', 'Term SM A'].map(cleClasse).toSet(), {'TERMINALE SM A'});
      expect(cleClasse('CP 1 A'), 'CP1 A');
      // Date impossible (le serveur refuse avant 1980) : ignorée, la ligne reste importable.
      final vieux = analyserImport(
          lignes: lireCsv(utf8.encode('NOM;PRÉNOMS;CLASSE;DATE DE NAISSANCE\nBAH;Ali;7ème A;06/07/1905\n')),
          classes: classes, existants: const []);
      expect(vieux.single.naissance, isNull);
      expect(vieux.single.etat, EtatLigne.incomplete);
      expect(vieux.single.remarques.first, startsWith('date impossible'));
      // Fichier réimporté : un élève déjà là, sans date de naissance, est un doublon probable.
      final re = analyserImport(
          lignes: lireCsv(utf8.encode('NOM;PRÉNOMS;CLASSE\nBAH;Ali;7ème A\nSOW;Awa;7ème A\n')),
          classes: classes,
          existants: const [(nom: 'BAH', prenoms: 'Ali', naissance: null)]);
      expect(re.map((x) => x.etat), [EtatLigne.doublon, EtatLigne.incomplete]);
      expect(nomPersonne(' Mamadou  Saliou ', 'diallo'), 'Mamadou Saliou DIALLO');
      expect(nomPersonne('Fatoumata', ''), 'Fatoumata');
      expect(cleClasse('PS'), 'PETITE SECTION');
    });

    test("Classes absentes : niveau, série et lettre retrouvés, regroupées par classe", () {
      final niveaux = <NiveauImport>[
        (id: 'cp1', nom: 'CP1', usage: '1ère année', series: null),
        (id: 'n10', nom: '10ème', usage: '10ème année', series: null),
        (id: 'n11', nom: '11ème', usage: '11ème année', series: 'SM,SS,SE'),
      ];
      String? d(String s) {
        final r = decomposerClasse(s, niveaux);
        return r == null ? null : '${r.niveau.id}|${r.serie}|${r.lettre}${r.probleme == null ? '' : '|!'}';
      }

      expect(d('10e B'), 'n10|null|B');
      expect(d('11eme ss a'), 'n11|SS|A');
      expect(d('1ère année A'), 'cp1|null|A');
      expect(d('12ème A'), isNull);
      expect(d('10ème Bis rouge'), 'n10|null|ROUGE|!');
      expect(d('11ème A'), 'n11|null|A|!'); // option manquante au lycée
      expect(d('11ème SL A'), 'n11|null|A|!'); // option hors du jeu de l'école
      const texte = 'NOM;PRÉNOMS;CLASSE\nDIALLO;Awa;10e B\nBAH;Ali;10ème b\nSOW;Fanta;12ème A\nBARRY;Ousmane;10ème A\n';
      final r = analyserImport(lignes: lireCsv(utf8.encode(texte)), classes: {'10ème A': 'c10a'}, existants: const []);
      final absentes = classesAbsentes(r, niveaux);
      expect([for (final a in absentes) '${a.nom}:${a.eleves}:${a.niveau?.id}'], ['10ème B:2:n10', '12ème A:1:null']);
    });

    test('Modèle Excel : onglets Élèves, Aide, Classes ; lignes sans élève ignorées', () {
      final classes = {'CP1 A': 'cp1', '7ème A': 'c7a', 'Terminale SM A': 'tsm'};
      final classeur = xl.Excel.decodeBytes(modeleExcelPour(classes.keys.toList()));
      expect(classeur.tables.keys, ['Élèves', 'Guide des classes', 'Aide', 'Classes']);
      final guide = [for (final r in classeur.tables['Guide des classes']!.rows) [for (final c in r) c?.value?.toString()]];
      expect(guide.any((l) => l.length > 2 && l[1] == 'Terminale' && '${l[2]}'.contains('13ème année')), isTrue);
      final lignes = [
        for (final r in classeur.tables['Élèves']!.rows) [for (final c in r) c?.value?.toString()],
      ];
      expect(lignes.first, titresImport);
      expect(lireEntete(lignes.first).keys.toSet(), colonnesImport.keys.toSet().difference({'parent'}));
      expect([for (final l in lignes.skip(1)) l[5]], classes.keys);
      expect(analyserImport(lignes: lignes, classes: classes, existants: const []), isEmpty);
      lignes[2] = ['DIALLO', 'Awa', 'F', '15/03/2014', null, '7ème A', 'Nouvelle', 'Fatoumata', 'bah', '620000000', 'Mère', null, '2023-145', null];
      final r = analyserImport(lignes: lignes, classes: classes, existants: const []);
      expect(r.single.classeId, 'c7a');
      expect(r.single.etat, EtatLigne.valide);
      expect(r.single.valeurs['ancien_matricule'], '2023-145');
      expect(r.single.parent, (complet: 'Fatoumata BAH', prenoms: 'Fatoumata', nom: 'BAH'));
      expect(r.single.lien, 'mere');
      // Ancien registre : une seule colonne PARENT.
      final ancien = analyserImport(
          lignes: lireCsv(utf8.encode('NOM;PRÉNOMS;CLASSE;PARENT\nBAH;Ali;7ème A;Mariama SOW\n')), classes: classes, existants: const []);
      expect(ancien.single.parent, (complet: 'Mariama SOW', prenoms: null, nom: null));
      // Un élève déjà dans ScolaGrid avec ce même ancien matricule : doublon probable.
      final d = analyserImport(lignes: lignes, classes: classes, existants: const [], anciensMatricules: {'2023-145': 'DIALLO Aïssatou'});
      expect(d.single.etat, EtatLigne.doublon);
      expect(d.single.remarques.last, 'même ancien matricule que DIALLO Aïssatou');
    });
  });
}
