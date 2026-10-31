/// Fonctions du personnel et droits attribuables.
/// Doit correspondre à serveur/migrations/004_personnel.sql : c'est le serveur
/// qui décide ; l'app s'en sert pour afficher et pour masquer ce qui serait refusé.
library;

const fonctions = {
  'fondateur': 'Fondateur',
  'directeur': 'Directeur',
  'directeur_etudes': 'Directeur des études',
  'surveillant': 'Surveillant',
  'secretaire': 'Secrétaire',
  'comptable': 'Comptable',
  'caissier': 'Caissier',
  'enseignant': 'Enseignant',
  'autre': 'Autre (gardien, chauffeur…)',
};

/// Fonctions que seul le fondateur peut attribuer.
const fonctionsDeDirection = {'fondateur', 'directeur'};

const droits = {
  'valider_remboursement': 'Valider un remboursement',
  'annuler_recu': 'Annuler un reçu',
  'gerer_emploi_du_temps': "Gérer l'emploi du temps",
  'planifier_evaluations': 'Planifier les évaluations',
  'saisir_notes': 'Saisir les notes',
  'faire_appel': "Faire l'appel",
  'justifier_absence': 'Justifier une absence',
  'preparer_paie': 'Préparer la paie',
  'valider_paie': 'Valider la paie',
  'verser_paie': 'Verser la paie',
  'consulter_tableau_bord': 'Consulter le tableau de bord',
  'autoriser_depense': 'Autoriser une dépense',
};

/// Droits par défaut de chaque fonction (le fondateur a tous les droits).
/// L'accès aux salaires n'est jamais automatique.
const droitsParDefaut = <String, Set<String>>{
  'directeur': {
    'valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
    'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord',
  },
  'directeur_etudes': {'gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence'},
  'surveillant': {'faire_appel', 'justifier_absence'},
  'enseignant': {'saisir_notes', 'faire_appel'},
  'comptable': {'consulter_tableau_bord'},
};

/// Droits qu'apportent ces fonctions, sans les exceptions.
Set<String> droitsDesFonctions(Iterable<String> f) =>
    f.contains('fondateur') ? droits.keys.toSet() : {for (final x in f) ...?droitsParDefaut[x]};

/// « K7PQ4XZM » devient « K7PQ-4XZM », plus facile à dicter.
String codeLisible(String code) => code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;
