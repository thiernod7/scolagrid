/// Modèle prérempli selon le système scolaire guinéen, pour éviter de tout saisir.
/// Les coefficients sont indicatifs : chaque école les ajuste ensuite.
library;

typedef Niveau = ({String nom, int ordre});

const cycles = {
  'maternelle': 'Maternelle',
  'primaire': 'Primaire',
  'college': 'Collège',
  'lycee': 'Lycée',
};

const niveauxParCycle = <String, List<Niveau>>{
  'maternelle': [
    (nom: 'Petite section', ordre: 1),
    (nom: 'Moyenne section', ordre: 2),
    (nom: 'Grande section', ordre: 3),
  ],
  'primaire': [
    (nom: 'CP1', ordre: 4),
    (nom: 'CP2', ordre: 5),
    (nom: 'CE1', ordre: 6),
    (nom: 'CE2', ordre: 7),
    (nom: 'CM1', ordre: 8),
    (nom: 'CM2', ordre: 9),
  ],
  'college': [
    (nom: '7ème', ordre: 10),
    (nom: '8ème', ordre: 11),
    (nom: '9ème', ordre: 12),
    (nom: '10ème', ordre: 13),
  ],
  'lycee': [
    (nom: '11ème', ordre: 14),
    (nom: '12ème', ordre: 15),
    (nom: 'Terminale', ordre: 16),
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
