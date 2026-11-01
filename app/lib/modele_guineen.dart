/// Modèle prérempli selon le système scolaire guinéen, pour éviter de tout saisir.
/// Les coefficients sont indicatifs : chaque école les ajuste ensuite.
library;

typedef Niveau = ({String nom, int ordre, String usage, String? examen, String? series});

const cycles = {
  'maternelle': 'Maternelle',
  'primaire': 'Primaire',
  'college': 'Collège',
  'lycee': 'Lycée',
};

/// Examens nationaux passés en fin de cycle.
const examens = {
  'CEE': "CEE (certificat d'études élémentaires)",
  'BEPC': "BEPC (brevet d'études du premier cycle)",
  'BAC': 'Baccalauréat',
};

/// Séries du lycée.
const seriesLycee = {
  'SM': 'Sciences mathématiques',
  'SE': 'Sciences expérimentales',
  'SS': 'Sciences sociales',
  'SL': 'Sciences littéraires',
};

const _toutes = 'SM,SE,SS,SL';

const niveauxParCycle = <String, List<Niveau>>{
  'maternelle': [
    (nom: 'Petite section', ordre: 1, usage: 'Petite section', examen: null, series: null),
    (nom: 'Moyenne section', ordre: 2, usage: 'Moyenne section', examen: null, series: null),
    (nom: 'Grande section', ordre: 3, usage: 'Grande section', examen: null, series: null),
  ],
  'primaire': [
    (nom: 'CP1', ordre: 4, usage: '1ère année', examen: null, series: null),
    (nom: 'CP2', ordre: 5, usage: '2ème année', examen: null, series: null),
    (nom: 'CE1', ordre: 6, usage: '3ème année', examen: null, series: null),
    (nom: 'CE2', ordre: 7, usage: '4ème année', examen: null, series: null),
    (nom: 'CM1', ordre: 8, usage: '5ème année', examen: null, series: null),
    (nom: 'CM2', ordre: 9, usage: '6ème année', examen: 'CEE', series: null),
  ],
  'college': [
    (nom: '7ème', ordre: 10, usage: '7ème année', examen: null, series: null),
    (nom: '8ème', ordre: 11, usage: '8ème année', examen: null, series: null),
    (nom: '9ème', ordre: 12, usage: '9ème année', examen: null, series: null),
    (nom: '10ème', ordre: 13, usage: '10ème année', examen: 'BEPC', series: null),
  ],
  'lycee': [
    (nom: '11ème', ordre: 14, usage: '11ème année', examen: null, series: _toutes),
    (nom: '12ème', ordre: 15, usage: '12ème année', examen: null, series: _toutes),
    (nom: 'Terminale', ordre: 16, usage: 'Terminale', examen: 'BAC', series: _toutes),
  ],
};

/// Matières et coefficients indicatifs, par cycle (la maternelle n'a pas de notes).
const matieresParCycle = <String, Map<String, double>>{
  'primaire': {
    'Français': 2,
    'Calcul': 2,
    "Sciences d'observation": 1,
    'Histoire': 1,
    'Géographie': 1,
    'Éducation civique et morale': 1,
    'Dessin': 1,
  },
  'college': {
    'Français': 3,
    'Mathématiques': 3,
    'Anglais': 2,
    'Physique-Chimie': 2,
    'Biologie': 2,
    'Histoire': 1,
    'Géographie': 1,
    'Éducation civique et morale': 1,
    'Éducation physique et sportive': 1,
  },
  'lycee': {
    'Mathématiques': 4,
    'Physique-Chimie': 3,
    'Biologie': 2,
    'Français': 3,
    'Philosophie': 2,
    'Anglais': 2,
    'Histoire-Géographie': 2,
    'Éducation physique et sportive': 1,
  },
};

/// Libellé de l'année scolaire en cours, à partir d'une date (rentrée en octobre).
String anneeScolairePour(DateTime d) {
  final debut = d.month >= 9 ? d.year : d.year - 1;
  return '$debut-${debut + 1}';
}
