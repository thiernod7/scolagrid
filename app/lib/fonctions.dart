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
  'lecteur': 'Lecteur (consultation seule)',
};

/// Fonctions que seul le fondateur peut attribuer.
const fonctionsDeDirection = {'fondateur', 'directeur'};

/// Ce qu'on choisit pour une personne : un titre, tel qu'on le dit à l'école,
/// qui porte une fonction (les droits). Une personne peut cumuler plusieurs titres.
const titres = <String, ({String fonction, String? libelle})>{
  'directeur_general': (fonction: 'directeur', libelle: 'Directeur général'),
  'directeur': (fonction: 'directeur', libelle: null),
  'proviseur': (fonction: 'directeur', libelle: 'Proviseur'),
  'principal': (fonction: 'directeur', libelle: 'Principal'),
  'directeur_primaire': (fonction: 'directeur', libelle: 'Directeur du primaire'),
  'censeur': (fonction: 'directeur_etudes', libelle: 'Censeur'),
  'directeur_etudes': (fonction: 'directeur_etudes', libelle: null),
  'surveillant_general': (fonction: 'surveillant', libelle: 'Surveillant général'),
  'surveillant': (fonction: 'surveillant', libelle: null),
  'secretaire': (fonction: 'secretaire', libelle: null),
  'comptable': (fonction: 'comptable', libelle: null),
  'caissier': (fonction: 'caissier', libelle: null),
  'enseignant': (fonction: 'enseignant', libelle: null),
  'autre': (fonction: 'autre', libelle: null),
  'lecteur': (fonction: 'lecteur', libelle: null),
};

/// « Proviseur », ou le nom de la fonction s'il n'y a pas de titre.
String nomTitre(String cle) => titres[cle]?.libelle ?? fonctions[titres[cle]?.fonction] ?? cle;

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
  'gerer_inscriptions': 'Inscrire et modifier les élèves',
  'encaisser': 'Encaisser les paiements',
  'voir_familles': 'Voir les parents et leurs téléphones',
  'voir_caisse': 'Voir la caisse et les paiements',
  'voir_personnel': 'Voir la liste du personnel',
};

/// Droits par défaut de chaque fonction (le fondateur a tous les droits).
/// L'accès aux salaires n'est jamais automatique.
const droitsParDefaut = <String, Set<String>>{
  'directeur': {
    'valider_remboursement', 'annuler_recu', 'gerer_emploi_du_temps',
    'planifier_evaluations', 'justifier_absence', 'consulter_tableau_bord', 'gerer_inscriptions',
    'voir_familles', 'voir_caisse', 'voir_personnel',
  },
  'directeur_etudes': {'gerer_emploi_du_temps', 'planifier_evaluations', 'justifier_absence'},
  'surveillant': {'faire_appel', 'justifier_absence'},
  'enseignant': {'saisir_notes', 'faire_appel'},
  'secretaire': {'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse'},
  'comptable': {'consulter_tableau_bord', 'gerer_inscriptions', 'encaisser', 'voir_familles', 'voir_caisse'},
  'caissier': {'encaisser', 'voir_familles', 'voir_caisse'},
};

/// Droits qu'apportent ces fonctions, sans les exceptions.
Set<String> droitsDesFonctions(Iterable<String> f) =>
    f.contains('fondateur') ? droits.keys.toSet() : {for (final x in f) ...?droitsParDefaut[x]};

/// « K7PQ4XZM » devient « K7PQ-4XZM », plus facile à dicter.
String codeLisible(String code) => code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;
