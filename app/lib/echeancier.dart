/// Calculs sans écran : sigles et découpage de la scolarité en échéances.
/// Testés dans test/schema_test.dart.
library;

const typesFrais = {
  'inscription': 'Inscription',
  'reinscription': 'Réinscription',
  'scolarite': 'Scolarité',
  'optionnel': 'Autre (cantine, transport, tenue…)',
};

const _moisNoms = [
  'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
  'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre',
];

/// Sigle ou code : 2 à 10 lettres majuscules ou chiffres.
bool codeValide(String code) => RegExp(r'^[A-Z0-9]{2,10}$').hasMatch(code);

String _sansAccents(String s) {
  const de = 'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿ';
  const vers = 'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOoooooUUUUuuuuYyy';
  final b = StringBuffer();
  for (final c in s.split('')) {
    final i = de.indexOf(c);
    b.write(i < 0 ? c : vers[i]);
  }
  return b.toString();
}

/// Propose un code à partir d'un nom : « Groupe scolaire Les Palmiers » → PALMIERS,
/// « Site de Donka » → DONKA.
String codeSuggere(String nom) {
  const vides = {
    'GROUPE', 'SCOLAIRE', 'ECOLE', 'COMPLEXE', 'INSTITUT', 'COLLEGE', 'LYCEE', 'PRIVE', 'PRIVEE',
    'SITE', 'LES', 'LE', 'LA', 'DE', 'DU', 'DES', 'ET', 'L', 'D', 'GS', 'CS',
  };
  final mots = _sansAccents(nom).toUpperCase().split(RegExp(r'[^A-Z0-9]+')).where((m) => m.isNotEmpty);
  final utiles = mots.where((m) => !vides.contains(m)).toList();
  final mot = utiles.isNotEmpty ? utiles.first : (mots.isNotEmpty ? mots.first : '');
  return mot.length > 8 ? mot.substring(0, 8) : mot;
}

class Echeance {
  const Echeance(this.ordre, this.libelle, this.montant, this.dateLimite);

  final int ordre;
  final String libelle;
  final int montant;
  final DateTime dateLimite;
}

DateTime _finDuMois(int annee, int mois) => DateTime(annee, mois + 1, 0);

/// Une échéance par mois, à payer avant la fin du mois. Ex. 9 mois d'octobre à juin.
List<Echeance> echeancesMensuelles({required int parMois, required DateTime premierMois, required int nbMois}) => [
      for (var i = 0; i < nbMois; i++)
        Echeance(
          i + 1,
          _moisNoms[(premierMois.month - 1 + i) % 12],
          parMois,
          _finDuMois(premierMois.year, premierMois.month + i),
        ),
    ];

/// Répartit les mois en tranches : 9 mois en 3 tranches → 3 + 3 + 3 ; en 2 → 5 + 4.
List<int> moisParTranche(int nbMois, int nbTranches) =>
    [for (var i = 0; i < nbTranches; i++) nbMois ~/ nbTranches + (i < nbMois % nbTranches ? 1 : 0)];

/// Le total de l'année en tranches égales (au millier près, le reste sur la
/// première), chacune à payer avant la fin de son dernier mois.
List<Echeance> echeancesEnTranches({required int total, required DateTime premierMois, required List<int> mois}) {
  final n = mois.length;
  final base = (total ~/ n) ~/ 1000 * 1000;
  final reste = total - base * n;
  var debut = 0;
  return [
    for (var i = 0; i < n; i++)
      Echeance(
        i + 1,
        n == 1 ? 'Année' : 'Tranche ${i + 1}',
        base + (i == 0 ? reste : 0),
        _finDuMois(premierMois.year, premierMois.month + (debut += mois[i]) - 1),
      ),
  ];
}
