part of 'configuration.dart';

/// Fiche d'un élève, comme dans la maquette : en-tête (photo, nom, statut),
/// quatre onglets (Dossier, Contacts, Finances, Suivi) et un pied d'actions.
/// Elle se pose à côté du tableau sur grand écran, glisse depuis la droite en
/// dessous, et s'ouvre en plein écran sur téléphone (FicheEleveScreen).

// Gestes sur un élève ------------------------------------------------------------
// Partagés entre la fiche et le menu « … » des lignes du tableau.

/// L'inscription de l'année en cours, sous la forme qu'attendent les gestes.
Future<Map<String, Object?>?> _inscriptionEnCours(String eleveId) => db.getOptional(
    '''SELECT i.*, c.nom AS classe, a.libelle AS annee FROM inscriptions i
       JOIN annees_scolaires a ON a.id = i.annee_id AND a.en_cours = 1
       JOIN classes c ON c.id = i.classe_id WHERE i.eleve_id = ?''',
    [eleveId]);

Future<void> _changerClasseEleve(BuildContext context, Map<String, Object?> ins) async {
  final classes = {
    for (final c in await db.getAll(
        '''SELECT c.id, c.nom, c.capacite, (SELECT count(*) FROM inscriptions i WHERE i.classe_id = c.id
             AND i.statut NOT IN ('annule', 'exclu', 'transfert_sortant')) AS effectif
           FROM classes c JOIN niveaux n ON n.id = c.niveau_id
           WHERE c.annee_id = ? AND c.site_id = ? AND c.id <> ? AND c.fermee = 0 ORDER BY n.ordre, c.nom''',
        [ins['annee_id'], ins['site_id'], ins['classe_id']]))
      c['id'] as String: '${c['nom']} · ${c['effectif']}${c['capacite'] == null ? '' : '/${c['capacite']}'}',
  };
  if (!context.mounted) return;
  if (classes.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aucune autre classe sur ce site.')));
    return;
  }
  var choix = classes.keys.first;
  final ok = await _formulaire(context, 'Changer de classe', (maj) => [
        const Text("Le matricule, les paiements et les notes suivent l'élève. Le changement est historisé."),
        _liste('Nouvelle classe', choix, classes, (v) => maj(() => choix = v)),
      ]);
  if (ok) await _modifier('inscriptions', ins['id'] as String, {'classe_id': choix});
}

/// Clore l'inscription : la place se libère, rien n'est effacé.
Future<void> _clore(BuildContext context, Map<String, Object?> ins) async {
  var statut = 'annule';
  final motif = TextEditingController();
  const motifs = {
    'annule': ('Inscription annulée', "L'inscription tombe avant d'avoir servi. La place se libère."),
    'transfert_sortant': ('Transfert vers une autre école', 'Il emporte son certificat de scolarité.'),
    'exclu': ('Exclusion', 'Décision de la direction.'),
    'suspendu': ('Suspension temporaire', "L'élève reste inscrit ; on pourra le reprendre."),
  };
  final ok = await _formulaire(context, "Clore l'inscription", (maj) => [
        const Text("La place se libère. Les paiements et l'historique restent au dossier ; le matricule n'est jamais réattribué.",
            style: TextStyle(fontSize: 13)),
        for (final m in motifs.entries)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => maj(() => statut = m.key),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: statut == m.key ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor),
                color: statut == m.key ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .4) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.value.$1, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                Text(m.value.$2, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
          ),
        TextField(controller: motif, decoration: _champ('Explication', aide: 'Obligatoire')),
      ]);
  if (!ok || motif.text.trim().length < 3) {
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Donnez une explication (3 lettres au moins).")));
    }
    return;
  }
  await _modifier('inscriptions', ins['id'] as String, {'statut': statut, 'motif': motif.text.trim()});
}

Future<void> _reprendreEleve(BuildContext context, Map<String, Object?> ins) async {
  if (await _confirmer(context, 'Reprendre cet élève (suspension levée) ?')) {
    await _modifier('inscriptions', ins['id'] as String, {'statut': ins['date_actif'] == null ? 'en_attente' : 'actif'});
  }
}

Future<Uint8List?> _photoOctets(Object? eleveId) async {
  final p = await db.getOptional('SELECT image FROM photos_eleves WHERE eleve_id = ?', [eleveId]);
  try {
    return p == null ? null : base64Decode(p['image'] as String);
  } catch (_) {
    return null;
  }
}

/// Arriérés de l'élève et règle de l'école pour ses documents.
/// Renvoie (permis, motif de levée du blocage).
Future<(bool, String?)> _blocageDocument(BuildContext context, Map<String, Object?> e) async {
  final messager = ScaffoldMessenger.of(context);
  final org = await db.get('SELECT blocage_documents FROM organisations WHERE id = ?', [e['organisation_id']]);
  final regle = org['blocage_documents'] as String? ?? 'alerte';
  if (regle == 'non') return (true, null);
  final ins = await _inscriptionEnCours(e['id'] as String);
  if (ins == null) return (true, null);
  final maintenant = DateTime.now();
  var retard = 0;
  for (final f in await situationInscription(ins['id'] as String)) {
    for (final x in f.echeances) {
      if (x.enRetard(maintenant)) retard += x.reste;
    }
  }
  if (retard <= 0 || !context.mounted) return (context.mounted, null);
  if (regle == 'alerte') {
    return (await _confirmer(context, "Cet élève a ${gnf(retard)} d'arriérés. Imprimer quand même ?"), null);
  }
  // Bloqué : seule la direction (fondateur, ou directeur de son site) lève le blocage.
  final direction = await db.getOptional(
      "SELECT 1 FROM rattachements WHERE user_id = ? AND organisation_id = ? AND actif = 1 "
      "AND (role = 'fondateur' OR (role = 'directeur' AND (site_id IS NULL OR site_id = ?)))",
      [monId, e['organisation_id'], ins['site_id']]);
  if (direction == null) {
    messager.showSnackBar(SnackBar(
        content: Text('Document bloqué : ${gnf(retard)} d\'arriérés. Seule la direction peut lever le blocage.')));
    return (false, null);
  }
  if (!context.mounted) return (false, null);
  final m = TextEditingController();
  final ok = await _formulaire(context, 'Lever le blocage', (_) => [
        Text("L'élève a ${gnf(retard)} d'arriérés : l'école bloque ses documents. Vous pouvez lever le blocage pour ce document, "
            'avec un motif gardé sur l\'impression.', style: const TextStyle(fontSize: 13)),
        TextField(controller: m, autofocus: true, decoration: _champ('Motif', aide: 'Par exemple : engagement de paiement du père')),
      ]);
  if (!ok || m.text.trim().length < 3) return (false, null);
  return (true, m.text.trim());
}

/// Attestation d'inscription : seulement pour un élève actif (frais
/// d'inscription réglés). La première impression est l'original ; ensuite,
/// duplicata numéroté avec motif. Chaque impression est notée.
Future<void> _imprimerAttestation(BuildContext context, Map<String, Object?> e, Map<String, Object?> ins) async {
  final messager = ScaffoldMessenger.of(context);
  if (ins['statut'] != 'actif') {
    messager.showSnackBar(const SnackBar(
        content: Text("Attestation disponible uniquement après règlement des frais d'inscription (élève actif).")));
    return;
  }
  final (permis, levee) = await _blocageDocument(context, e);
  if (!permis || !context.mounted) return;
  final deja = (await db.get(
      "SELECT count(*) AS n FROM impressions_documents WHERE inscription_id = ? AND type_document = 'attestation_inscription'",
      [ins['id']]))['n'] as int;
  String? motif;
  if (deja > 0) {
    final m = TextEditingController();
    if (!context.mounted) return;
    final ok = await _formulaire(context, 'Duplicata n° $deja', (_) => [
          const Text("L'attestation a déjà été imprimée. Cette nouvelle impression portera la mention DUPLICATA."),
          TextField(controller: m, autofocus: true, decoration: _champ('Motif', aide: 'Ex. original perdu')),
        ]);
    if (!ok || m.text.trim().length < 3) return;
    motif = m.text.trim();
  }
  final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [e['organisation_id']]);
  final poste = await cePoste();
  await _inserer('impressions_documents', {
    'organisation_id': e['organisation_id'],
    'eleve_id': e['id'],
    'inscription_id': ins['id'],
    'type_document': 'attestation_inscription',
    'rang': deja + 1,
    'motif': motif,
    'motif_levee': levee,
    'par': monId,
    'poste_id': poste?['poste_id'],
  });
  final pdf = await attestationPdf(
    photo: await _photoOctets(e['id']),
    ecole: Map.of(ecole),
    eleve: e,
    classe: '${ins['classe']}',
    annee: '${ins['annee']}',
    date: DateTime.now(),
    rang: deja + 1,
    images: await _imagesEcole(e['organisation_id']),
  );
  await Printing.layoutPdf(
      onLayout: (_) async => pdf, name: 'Attestation ${e['matricule']}${deja > 0 ? ' duplicata $deja' : ''}');
}

/// Certificat de scolarité : toutes les années passées dans l'école (même
/// après le départ de l'élève). Original, puis duplicatas avec motif.
Future<void> _imprimerCertificat(BuildContext context, Map<String, Object?> e) async {
  final messager = ScaffoldMessenger.of(context);
  final annees = await db.getAll(
      '''SELECT a.libelle, c.nom AS classe, i.statut, i.date_sortie FROM inscriptions i
         JOIN annees_scolaires a ON a.id = i.annee_id JOIN classes c ON c.id = i.classe_id
         WHERE i.eleve_id = ? AND i.statut <> 'annule' ORDER BY a.debut''',
      [e['id']]);
  if (annees.isEmpty) {
    messager.showSnackBar(const SnackBar(content: Text('Aucune année de scolarité enregistrée pour cet élève.')));
    return;
  }
  final (permis, levee) = await _blocageDocument(context, e);
  if (!permis || !context.mounted) return;
  final deja = (await db.get(
      "SELECT count(*) AS n FROM impressions_documents WHERE eleve_id = ? AND type_document = 'certificat_scolarite'",
      [e['id']]))['n'] as int;
  String? motif;
  if (deja > 0) {
    final m = TextEditingController();
    if (!context.mounted) return;
    final ok = await _formulaire(context, 'Duplicata n° $deja', (_) => [
          const Text('Le certificat a déjà été imprimé. Cette nouvelle impression portera la mention DUPLICATA.'),
          TextField(controller: m, autofocus: true, decoration: _champ('Motif', aide: 'Ex. dossier de transfert, bourse')),
        ]);
    if (!ok || m.text.trim().length < 3) return;
    motif = m.text.trim();
  }
  final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [e['organisation_id']]);
  final poste = await cePoste();
  await _inserer('impressions_documents', {
    'organisation_id': e['organisation_id'],
    'eleve_id': e['id'],
    'inscription_id': null,
    'type_document': 'certificat_scolarite',
    'rang': deja + 1,
    'motif': motif,
    'motif_levee': levee,
    'par': monId,
    'poste_id': poste?['poste_id'],
  });
  final derniere = annees.last;
  final pdf = await certificatPdf(
    photo: await _photoOctets(e['id']),
    ecole: Map.of(ecole),
    eleve: e,
    parcours: [for (final a in annees) (annee: '${a['libelle']}', classe: '${a['classe']}')],
    sortie: const {'transfert_sortant', 'exclu', 'diplome'}.contains(derniere['statut']) ? derniere['date_sortie'] as String? : null,
    date: DateTime.now(),
    rang: deja + 1,
    images: await _imagesEcole(e['organisation_id']),
  );
  await Printing.layoutPdf(
      onLayout: (_) async => pdf, name: 'Certificat ${e['matricule']}${deja > 0 ? ' duplicata $deja' : ''}');
}

Future<void> _modifierIdentiteEleve(BuildContext context, Map<String, Object?> e) async {
  TextEditingController c(String col) => TextEditingController(text: e[col] as String? ?? '');
  final champs = {
    'nom': c('nom'),
    'prenoms': c('prenoms'),
    'lieu_naissance': c('lieu_naissance'),
    'nationalite': c('nationalite'),
    'quartier': c('quartier'),
    'matricule_etat': c('matricule_etat'),
    'ancien_matricule': c('ancien_matricule'),
    'allergies': c('allergies'),
    'sante': c('sante'),
  };
  const libelles = {
    'nom': 'Nom',
    'prenoms': 'Prénom(s)',
    'lieu_naissance': 'Lieu de naissance',
    'nationalite': 'Nationalité',
    'quartier': 'Quartier',
    'matricule_etat': "Matricule d'État",
    'ancien_matricule': "Ancien matricule de l'école",
    'allergies': 'Allergies',
    'sante': 'Traitement ou condition',
  };
  var naissance = DateTime.tryParse('${e['date_naissance']}');
  var sexe = e['sexe'] as String?;
  var groupe = e['groupe_sanguin'] as String?;
  final ok = await _formulaire(context, "Modifier l'identité", (maj) => [
        Text('Matricule ${e['matricule']} : il ne change jamais.', style: const TextStyle(fontSize: 13)),
        for (final k in champs.keys) TextField(controller: champs[k], decoration: _champ(libelles[k]!)),
        _liste<String?>('Sexe', sexe, const {null: 'Non renseigné', 'M': 'Masculin', 'F': 'Féminin'}, (v) => maj(() => sexe = v)),
        _liste<String?>('Groupe sanguin', groupe, {
          null: 'Non renseigné',
          for (final g in const ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']) g: g,
        }, (v) => maj(() => groupe = v)),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await _choisirDate(context, naissance);
            if (d != null) maj(() => naissance = d);
          },
          icon: const Icon(Icons.cake_outlined, size: 16),
          label: Text(naissance == null ? 'Date de naissance' : 'Né(e) le ${_dateLisible(_date(naissance!))}'),
        ),
      ]);
  if (!ok || champs['nom']!.text.trim().isEmpty || champs['prenoms']!.text.trim().isEmpty) return;
  await _modifier('eleves', e['id'] as String, {
    for (final k in champs.keys)
      k: champs[k]!.text.trim().isEmpty ? null : (k == 'nom' ? champs[k]!.text.trim().toUpperCase() : champs[k]!.text.trim()),
    'sexe': sexe,
    'groupe_sanguin': groupe,
    'date_naissance': naissance == null ? null : _date(naissance!),
  });
}

Future<void> _ajouterContactEleve(BuildContext context, Map<String, Object?> e) async {
  final tel = TextEditingController();
  final prenoms = TextEditingController();
  final nom = TextEditingController();
  final profession = TextEditingController();
  var lien = 'mere';
  Map<String, Object?>? connu;
  final ok = await _formulaire(context, 'Ajouter un contact', (maj) => [
        TextField(
          controller: tel,
          keyboardType: TextInputType.phone,
          decoration: _champ('Téléphone'),
          onChanged: (v) async {
            final n = numeroInternational(v);
            final c = n.length < 12
                ? null
                : await db.getOptional("SELECT * FROM contacts WHERE organisation_id = ? AND replace(telephone, ' ', '') = ?",
                    [e['organisation_id'], n]);
            maj(() {
              connu = c;
              if (c != null) {
                prenoms.text = '${c['prenoms'] ?? ''}';
                nom.text = '${c['nom'] ?? c['nom_complet']}';
                profession.text = '${c['profession'] ?? ''}';
              }
            });
          },
        ),
        if (connu != null)
          Text('Contact déjà connu : ${connu!['nom_complet']}.', style: const TextStyle(color: Couleurs.regle))
        else ...[
          TextField(controller: prenoms, textCapitalization: TextCapitalization.words, decoration: _champ('Prénom(s)')),
          TextField(controller: nom, textCapitalization: TextCapitalization.characters, decoration: _champ('Nom')),
        ],
        _liste('Type de contact', lien, liensFamille, (v) => maj(() => lien = v)),
        TextField(controller: profession, enabled: connu == null, decoration: _champ('Profession', aide: 'Facultatif')),
      ]);
  if (!ok) return;
  if (connu == null && (prenoms.text.trim().isEmpty || nom.text.trim().isEmpty)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Le prénom et le nom du contact sont demandés.')));
    }
    return;
  }
  final maintenant = _maintenant();
  final eleveId = e['id'] as String;
  await db.writeTransaction((tx) async {
    var contactId = connu?['id'] as String?;
    if (contactId == null) {
      contactId = (await tx.get('SELECT uuid() AS id'))['id'] as String;
      await tx.execute(
          'INSERT INTO contacts (id, organisation_id, nom_complet, prenoms, nom, telephone, profession, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [contactId, e['organisation_id'], nomPersonne(prenoms.text, nom.text), prenoms.text.trim(), nom.text.trim().toUpperCase(),
            tel.text.trim().isEmpty ? null : numeroInternational(tel.text),
            profession.text.trim().isEmpty ? null : profession.text.trim(), maintenant, maintenant]);
    }
    final deja = await tx.getOptional('SELECT 1 FROM eleves_contacts WHERE eleve_id = ? AND contact_id = ?', [eleveId, contactId]);
    if (deja != null) return;
    final sansTuteur =
        await tx.getOptional('SELECT 1 FROM eleves_contacts WHERE eleve_id = ? AND tuteur_principal = 1', [eleveId]) == null;
    final sansPayeur =
        await tx.getOptional('SELECT 1 FROM eleves_contacts WHERE eleve_id = ? AND responsable_financier = 1', [eleveId]) == null;
    await tx.execute(
        'INSERT INTO eleves_contacts (id, organisation_id, eleve_id, contact_id, lien, tuteur_principal, responsable_financier, '
        'created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
        [e['organisation_id'], eleveId, contactId, lien, sansTuteur ? 1 : 0, sansPayeur ? 1 : 0, maintenant, maintenant]);
  });
}

/// Un seul tuteur principal et un seul payeur : on retire d'abord l'ancien.
Future<void> _designerContact(String eleveId, String lienId, String colonne) => db.writeTransaction((tx) async {
      final m = _maintenant();
      await tx.execute(
          'UPDATE eleves_contacts SET $colonne = 0, updated_at = ? WHERE eleve_id = ? AND $colonne = 1', [m, eleveId]);
      await tx.execute('UPDATE eleves_contacts SET $colonne = 1, updated_at = ? WHERE id = ?', [m, lienId]);
    });

Future<void> _choisirPhotoEleve(BuildContext context, Map<String, Object?> e) async {
  final source = cameraDisponible
      ? await showModalBottomSheet<bool>(
          context: context,
          builder: (context) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Prendre la photo'),
                  onTap: () => Navigator.pop(context, true)),
              ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('Choisir dans la galerie'),
                  onTap: () => Navigator.pop(context, false)),
            ]),
          ),
        )
      : false;
  if (source == null || !context.mounted) return;
  final p = await choisirPhoto(context, camera: source);
  if (p != null) await enregistrerPhoto(orgId: e['organisation_id'] as String, eleveId: e['id'] as String, photo: p);
}

// Petits éléments de présentation ---------------------------------------------------

/// Titre de rubrique en petites capitales grises (« DATES TRACÉES »).
Widget _rubrique(BuildContext context, String titre, {Widget? droite}) => Row(children: [
      Expanded(
        child: Text(titre.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: .6,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
      ?droite,
    ]);

/// Un champ en lecture : libellé gris au-dessus, valeur dessous.
class _ChampLu extends StatelessWidget {
  const _ChampLu(this.libelle, this.valeur, {this.mono = false, this.attenue = false});

  final String libelle;
  final String? valeur;
  final bool mono;
  final bool attenue;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final v = valeur ?? '—';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(libelle, style: TextStyle(fontSize: 12, color: gris)),
      const SizedBox(height: 2),
      Text(v,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: mono
              ? styleMono.copyWith(fontSize: 14, color: attenue ? gris : null)
              : TextStyle(fontSize: 14, color: attenue || valeur == null ? gris : null)),
    ]);
  }
}

/// Deux colonnes de champs, avec 20 px entre les lignes.
Widget _deuxColonnes(List<Widget> champs) => LayoutBuilder(builder: (context, c) {
      final l = (c.maxWidth - 20) / 2;
      return Wrap(spacing: 20, runSpacing: 20, children: [for (final x in champs) SizedBox(width: l, child: x)]);
    });

/// Petite pastille rouge « santé » posée à côté du nom.
class AlerteSante extends StatelessWidget {
  const AlerteSante({super.key, required this.eleve});

  final Map<String, Object?> eleve;

  static bool concerne(Map<String, Object?> e) => e['allergies'] != null || e['sante'] != null;

  @override
  Widget build(BuildContext context) {
    if (!concerne(eleve)) return const SizedBox.shrink();
    return Tooltip(
      message: [
        'Alerte santé',
        if (eleve['sante'] != null) '${eleve['sante']}',
        if (eleve['allergies'] != null) 'Allergies : ${eleve['allergies']}',
      ].join('\n'),
      child: Container(
        width: 20,
        height: 20,
        decoration: const BoxDecoration(color: Couleurs.retardFond, shape: BoxShape.circle),
        child: const Icon(Icons.monitor_heart_outlined, size: 14, color: Couleurs.retard),
      ),
    );
  }
}

// La fiche -----------------------------------------------------------------------

/// Plein écran (téléphone, ou lien depuis un autre écran).
class FicheEleveScreen extends StatelessWidget {
  const FicheEleveScreen({super.key, required this.espace, required this.eleveId});

  final Espace espace;
  final String eleveId;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: FicheEleve(espace: espace, eleveId: eleveId, onFermer: () => Navigator.of(context).maybePop()),
            ),
          ),
        ),
      );
}

class FicheEleve extends StatefulWidget {
  const FicheEleve({super.key, required this.espace, required this.eleveId, required this.onFermer});

  final Espace espace;
  final String eleveId;
  final VoidCallback onFermer;

  @override
  State<FicheEleve> createState() => _FicheEleveState();
}

class _FicheEleveState extends State<FicheEleve> {
  bool _peutModifier = false;
  bool _voitCaisse = false;

  /// Inscrire ou encaisser depuis la fiche (un lecteur ne fait que regarder).
  bool _agitCaisse = false;

  @override
  void initState() {
    super.initState();
    _droits();
  }

  @override
  void didUpdateWidget(FicheEleve ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.eleveId != widget.eleveId) _droits();
  }

  Future<void> _droits() async {
    final e = await db.getOptional('SELECT organisation_id, site_id FROM eleves WHERE id = ?', [widget.eleveId]);
    if (e == null) return;
    final ok = await jAiLeDroit(e['organisation_id'] as String, e['site_id'] as String?, 'gerer_inscriptions');
    final caisse = await jAiLeDroit(e['organisation_id'] as String, e['site_id'] as String?, 'encaisser');
    final voit = await jAiLeDroit(e['organisation_id'] as String, e['site_id'] as String?, 'voir_caisse') ||
        await jAiLeDroit(e['organisation_id'] as String, e['site_id'] as String?, 'consulter_tableau_bord');
    if (mounted) {
      setState(() {
        _peutModifier = ok;
        _agitCaisse = caisse || ok;
        _voitCaisse = caisse || ok || voit;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT e.*, s.nom AS site, so.nom AS site_origine,
             (SELECT p.updated_at FROM photos_eleves p WHERE p.eleve_id = e.id) AS photo_maj,
             (SELECT max(h.quand) FROM historique_eleves h WHERE h.eleve_id = e.id AND h.evenement = 'mutation') AS date_mutation,
             (SELECT a2.libelle FROM annees_scolaires a2 WHERE a2.organisation_id = e.organisation_id AND a2.etat = 'inscriptions'
              AND NOT EXISTS (SELECT 1 FROM inscriptions i2 WHERE i2.eleve_id = e.id AND i2.annee_id = a2.id AND i2.statut <> 'annule')
              LIMIT 1) AS reinscription_ouverte,
             i.id AS ins_id, i.statut, i.type_admission, i.date_effective, i.date_actif, i.date_sortie, i.motif,
             i.created_at AS ins_saisie, i.redoublant, nv.cycle AS cycle, i.classe_id, i.annee_id, i.site_id AS ins_site, c.nom AS classe, a.libelle AS annee
           FROM eleves e
           LEFT JOIN sites s ON s.id = e.site_id
           LEFT JOIN sites so ON so.id = e.site_origine_id
           LEFT JOIN annees_scolaires a ON a.organisation_id = e.organisation_id AND a.en_cours = 1
           LEFT JOIN inscriptions i ON i.eleve_id = e.id AND i.annee_id = a.id
           LEFT JOIN classes c ON c.id = i.classe_id
           LEFT JOIN niveaux nv ON nv.id = c.niveau_id
           WHERE e.id = ?''',
        parametres: [widget.eleveId],
        builder: (context, l) {
          if (l.isEmpty) return const Center(child: Text('Élève introuvable sur ce poste.'));
          final e = Map<String, Object?>.from(l.first);
          final ins = e['ins_id'] == null
              ? null
              : <String, Object?>{
                  'id': e['ins_id'],
                  'annee_id': e['annee_id'],
                  'site_id': e['ins_site'],
                  'classe_id': e['classe_id'],
                  'statut': e['statut'],
                  'date_actif': e['date_actif'],
                  'classe': e['classe'],
                  'annee': e['annee'],
                };
          return DefaultTabController(
            length: 4,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _entete(context, e),
              const SizedBox(height: 12),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _Onglets(sante: AlerteSante.concerne(e))),
              Expanded(
                child: TabBarView(children: [
                  _OngletDossier(eleve: e, inscription: ins, modifiable: _peutModifier),
                  _OngletContacts(eleve: e, modifiable: _peutModifier),
                  _OngletFinances(espace: widget.espace, eleve: e, inscription: ins, visible: _voitCaisse),
                  _OngletSuivi(eleve: e),
                ]),
              ),
              // Un lecteur consulte seulement : pas de pied d'actions.
              if (_peutModifier || _agitCaisse) _pied(context, e, ins),
            ]),
          );
        },
      );

  Widget _entete(BuildContext context, Map<String, Object?> e) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final telephone = MediaQuery.sizeOf(context).width < 640;
    return Container(
      padding: EdgeInsets.all(telephone ? 12 : 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          customBorder: const CircleBorder(),
          onTap: _peutModifier ? () => _choisirPhotoEleve(context, e) : null,
          child: PhotoEleve(eleveId: widget.eleveId, nom: _nomEleve(e), version: e['photo_maj'] as String?, taille: telephone ? 52 : 72),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(_nomEleve(e), style: TextStyle(fontSize: telephone ? 16 : 18, fontWeight: FontWeight.w600)),
              AlerteSante(eleve: e),
              if (e['statut'] != null) etatInscription(e['statut'] as String) else const Etat('Pas inscrit cette année'),
              if (e['redoublant'] == 1) const Etat('Redoublant', ton: Ton.attente, icone: Icons.replay),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${e['matricule']}', style: styleMono.copyWith(fontSize: telephone ? 11 : 12, color: gris)),
              if (e['classe'] != null) Text('${e['classe']}', style: TextStyle(fontSize: telephone ? 13 : 14, color: gris)),
              if (e['site'] != null) Text('${e['site']}', style: TextStyle(fontSize: telephone ? 13 : 14, color: gris)),
            ]),
          ]),
        ),
        IconButton(
          tooltip: 'Fermer',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 18),
          onPressed: widget.onFermer,
        ),
      ]),
    );
  }

  Widget _pied(BuildContext context, Map<String, Object?> e, Map<String, Object?>? ins) {
    if (!_peutModifier) return const SizedBox.shrink();
    final sorti = ins == null || const {'annule', 'exclu', 'transfert_sortant', 'diplome'}.contains(ins['statut']);
    void reinscrire() => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => InscrireScreen(espace: widget.espace, eleveId: widget.eleveId)));
    // Les gestes de la fiche : (libellé, icône, action, en rouge ?).
    final gestes = <(String, IconData, VoidCallback, bool)>[
      // Inscriptions de la rentrée prochaine ouvertes, élève pas encore réinscrit.
      if (ins != null && e['reinscription_ouverte'] != null && ins['statut'] != 'diplome')
        ('Réinscrire pour ${e['reinscription_ouverte']}', Icons.how_to_reg_outlined, reinscrire, false),
      if (ins == null)
        ('Réinscrire', Icons.how_to_reg_outlined, reinscrire, false)
      else if (ins['statut'] == 'suspendu')
        ('Reprendre', Icons.undo, () => _reprendreEleve(context, ins), false)
      else if (!sorti) ...[
        ('Changer de classe', Icons.swap_horiz, () => _changerClasseEleve(context, ins), false),
        ("Clore l'inscription", Icons.block, () => _clore(context, ins), true),
      ],
    ];
    final schema = Theme.of(context).colorScheme;
    final decoration = BoxDecoration(color: schema.surface, border: Border(top: BorderSide(color: Theme.of(context).dividerColor)));

    // Téléphone : une seule ligne — Encaisser, Modifier, et le reste dans « ⋯ ».
    if (MediaQuery.sizeOf(context).width < 640) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: decoration,
        child: Row(children: [
          Expanded(
            child: _agitCaisse && ins != null
                ? FilledButton.icon(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => EncaisserScreen(espace: widget.espace, eleveId: widget.eleveId))),
                    icon: const Icon(Icons.account_balance_wallet_outlined, size: 16),
                    label: const Text('Encaisser'),
                  )
                : FilledButton.icon(
                    onPressed: () => _modifierIdentiteEleve(context, e),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Modifier'),
                  ),
          ),
          if (_agitCaisse && ins != null) ...[
            const SizedBox(width: 6),
            IconButton.outlined(
              tooltip: 'Modifier',
              onPressed: () => _modifierIdentiteEleve(context, e),
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
          ],
          if (gestes.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: 'Autres actions',
              icon: const Icon(Icons.more_horiz),
              onSelected: (i) => gestes[i].$3(),
              itemBuilder: (_) => [
                for (var i = 0; i < gestes.length; i++)
                  PopupMenuItem(
                    value: i,
                    child: Row(children: [
                      Icon(gestes[i].$2, size: 18, color: gestes[i].$4 ? Couleurs.retard : null),
                      const SizedBox(width: 10),
                      Text(gestes[i].$1, style: TextStyle(color: gestes[i].$4 ? Couleurs.retard : null)),
                    ]),
                  ),
              ],
            ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: decoration,
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: () => _modifierIdentiteEleve(context, e),
          icon: const Icon(Icons.edit_outlined, size: 15),
          label: const Text('Modifier'),
        ),
        for (final g in gestes)
          OutlinedButton.icon(
            style: g.$4 ? OutlinedButton.styleFrom(foregroundColor: Couleurs.retard) : null,
            onPressed: g.$3,
            icon: Icon(g.$2, size: 15),
            label: Text(g.$1),
          ),
      ]),
    );
  }
}

/// Onglets en « pilule » grise, l'onglet choisi en blanc.
class _Onglets extends StatelessWidget {
  const _Onglets({required this.sante});

  final bool sante;

  @override
  Widget build(BuildContext context) {
    final schema = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: Couleurs.doux(context), borderRadius: BorderRadius.circular(8)),
        child: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerHeight: 0,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: schema.surface,
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          labelColor: schema.onSurface,
          unselectedLabelColor: schema.onSurfaceVariant,
          labelStyle: const TextStyle(fontFamily: policeTexte, fontSize: 14, fontWeight: FontWeight.w500),
          unselectedLabelStyle: const TextStyle(fontFamily: policeTexte, fontSize: 14, fontWeight: FontWeight.w400),
          labelPadding: const EdgeInsets.symmetric(horizontal: 10),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          tabs: [
            const Tab(height: 30, text: 'Dossier'),
            const Tab(height: 30, text: 'Contacts'),
            const Tab(height: 30, text: 'Finances'),
            Tab(
              height: 30,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Suivi'),
                if (sante) ...[const SizedBox(width: 6), const Icon(Icons.monitor_heart_outlined, size: 14, color: Couleurs.retard)],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// Onglet Dossier ---------------------------------------------------------------------

class _OngletDossier extends StatelessWidget {
  const _OngletDossier({required this.eleve, required this.inscription, required this.modifiable});

  final Map<String, Object?> eleve;
  final Map<String, Object?>? inscription;
  final bool modifiable;

  @override
  Widget build(BuildContext context) {
    final e = eleve;
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final mute = e['site_origine_id'] != e['site_id'];
    final jalons = <(String, Object?, Object?)>[
      ('Première inscription', e['date_premiere_inscription'], null),
      if (e['annee'] != null && e['date_effective'] != null) ('Inscription ${e['annee']}', e['date_effective'], e['ins_saisie']),
      ('Passage « Actif »', e['date_actif'], null),
      ('Changement de classe', e['date_mutation'], null),
      ('Sortie', e['date_sortie'], null),
    ].where((j) => j.$2 != null).toList();

    return ListView(padding: const EdgeInsets.all(16), children: [
      _deuxColonnes([
        _ChampLu('Matricule système', '${e['matricule']}', mono: true),
        e['matricule_etat'] == null
            ? const _ChampLu("Matricule d'État", "en attente d'attribution", attenue: true)
            : _ChampLu("Matricule d'État", '${e['matricule_etat']}', mono: true),
        if (e['ancien_matricule'] != null) _ChampLu("Ancien matricule de l'école", '${e['ancien_matricule']}', mono: true),
        _ChampLu('Nom', '${e['nom']}'),
        _ChampLu('Prénom(s)', '${e['prenoms']}'),
        _ChampLu('Sexe', switch (e['sexe']) { 'M' => 'Masculin', 'F' => 'Féminin', _ => null }),
        _ChampLu('Date de naissance', e['date_naissance'] == null ? null : _dateLisible(e['date_naissance'])),
        _ChampLu('Lieu de naissance', e['lieu_naissance'] as String?),
        _ChampLu('Nationalité', e['nationalite'] as String?),
        _ChampLu('Quartier', e['quartier'] as String?),
        _ChampLu('Site actuel', [e['site'], if (mute && e['site_origine'] != null) '(origine ${e['site_origine']})'].join(' ')),
      ]),
      const SizedBox(height: 28),
      _Parcours(eleveId: e['id'] as String),
      _rubrique(context, 'Dates tracées'),
      const SizedBox(height: 12),
      for (var i = 0; i < jalons.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 12,
              child: Stack(alignment: Alignment.topCenter, children: [
                if (i < jalons.length - 1)
                  Positioned(top: 12, bottom: 0, child: Container(width: 1, color: Theme.of(context).dividerColor)),
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Container(
                      width: 6, height: 6, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle)),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: i < jalons.length - 1 ? 16 : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(jalons[i].$1, style: const TextStyle(fontSize: 14))),
                    Text(_dateLisible(jalons[i].$2), style: styleMono.copyWith(fontSize: 14)),
                  ]),
                  if (jalons[i].$3 != null && _dateLisible(jalons[i].$3) != _dateLisible(jalons[i].$2))
                    Row(children: [
                      Expanded(child: Text('saisie le', style: TextStyle(fontSize: 12, color: gris))),
                      Text(_dateLisible(jalons[i].$3), style: styleMono.copyWith(fontSize: 12, color: gris)),
                    ]),
                ]),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 28),
      _Pieces(eleve: e, modifiable: modifiable),
      const SizedBox(height: 28),
      _rubrique(context, 'Documents produits par le système'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: inscription == null ? null : () => _imprimerAttestation(context, e, inscription!),
          icon: const Icon(Icons.description_outlined, size: 15),
          label: const Text("Attestation d'inscription"),
        ),
        OutlinedButton.icon(
          onPressed: modifiable ? () => _imprimerCertificat(context, e) : null,
          icon: const Icon(Icons.description_outlined, size: 15),
          label: const Text('Certificat de scolarité'),
        ),
      ]),
      const SizedBox(height: 8),
      Requete(
        '''SELECT d.*, p.nom_complet AS auteur FROM impressions_documents d
           LEFT JOIN personnel p ON p.user_id = d.par AND p.organisation_id = d.organisation_id
           WHERE d.eleve_id = ? ORDER BY d.created_at DESC''',
        parametres: [e['id']],
        builder: (context, docs) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final d in docs)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Expanded(
                  child: Text(
                      '${const {
                        'attestation_inscription': "Attestation d'inscription",
                        'certificat_scolarite': 'Certificat de scolarité',
                        'decharge_remboursement': 'Décharge de remboursement',
                      }[d['type_document']] ?? d['type_document']} · '
                      '${d['rang'] == 1 ? 'original' : 'duplicata n° ${(d['rang'] as int) - 1}'}'
                      '${d['auteur'] != null ? ' · ${d['auteur']}' : ''}',
                      style: TextStyle(fontSize: 12, color: gris)),
                ),
                Text(_dateLisible(d['created_at']), style: styleMono.copyWith(fontSize: 12, color: gris)),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

/// Toutes les années passées dans l'école (affiché à partir de deux).
class _Parcours extends StatelessWidget {
  const _Parcours({required this.eleveId});

  final String eleveId;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT a.libelle, c.nom AS classe, i.type_admission, i.statut,
             (SELECT coalesce(sum(l.montant_gnf), 0) FROM lignes_encaissement l
              JOIN encaissements e ON e.id = l.encaissement_id AND e.statut = 'valide'
              WHERE l.inscription_id = i.id) AS regle
           FROM inscriptions i JOIN annees_scolaires a ON a.id = i.annee_id JOIN classes c ON c.id = i.classe_id
           WHERE i.eleve_id = ? ORDER BY a.debut''',
        parametres: [eleveId],
        builder: (context, annees) {
          if (annees.length < 2) return const SizedBox.shrink();
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          return Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _rubrique(context, "Parcours dans l'école"),
              const SizedBox(height: 12),
              for (final a in annees)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Text('${a['libelle']}', style: styleMono.copyWith(fontSize: 12, color: gris)),
                    const SizedBox(width: 12),
                    Expanded(child: Text('${a['classe']}', style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis)),
                    Text(switch (a['type_admission']) { 'reinscription' => 'Réinscription', 'transfert' => 'Transfert', _ => 'Inscription' },
                        style: TextStyle(fontSize: 12, color: gris)),
                    const SizedBox(width: 12),
                    Text(gnf(a['regle']), style: styleMono.copyWith(fontSize: 12)),
                  ]),
                ),
            ]),
          );
        },
      );
}

/// Pièces fournies par la famille : une coche ou un cercle vide, en lecture.
/// Avec le droit d'inscrire, « Mettre à jour les pièces » ouvre une fenêtre où
/// l'on coche, puis on enregistre : pas de coche par simple frôlement.
class _Pieces extends StatelessWidget {
  const _Pieces({required this.eleve, required this.modifiable});

  final Map<String, Object?> eleve;
  final bool modifiable;

  @override
  Widget build(BuildContext context) => Requete(
        // Se met à jour quand l'école change sa liste.
        'SELECT count(*) AS n, max(updated_at) AS m FROM pieces_dossier WHERE organisation_id = ?',
        parametres: [eleve['organisation_id']],
        builder: (context, _) => FutureBuilder<List<PieceDossier>>(
          future: piecesDe(eleve['organisation_id'] as String),
          builder: (context, s) {
            final liste = (s.data ?? piecesStandard)
                .where((p) => p.concerne(eleve['type_admission'] as String?, eleve['cycle'] as String?))
                .toList();
            final fournies = '${eleve['pieces_dossier'] ?? ''}'.split(',').where((c) => c.isNotEmpty).toSet();
            final gris = Theme.of(context).colorScheme.onSurfaceVariant;
            final nb = liste.where((p) => fournies.contains(p.code)).length;
            final manquantes = liste.where((p) => p.obligatoire && !fournies.contains(p.code)).length;
            Future<void> mettreAJour() async {
              final choisies = {...fournies};
              final ok = await _formulaire(context, 'Pièces fournies par la famille', (maj) => [
                    for (final p in liste)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: choisies.contains(p.code),
                        title: Text(p.obligatoire ? '${p.libelle} (obligatoire)' : p.libelle),
                        onChanged: (v) => maj(() => v == true ? choisies.add(p.code) : choisies.remove(p.code)),
                      ),
                  ]);
              if (!ok || setEquals(choisies, fournies)) return;
              await _modifier('eleves', eleve['id'] as String, {'pieces_dossier': piecesEnTexte(choisies, s.data ?? piecesStandard)});
            }

            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _rubrique(context, 'Pièces fournies par la famille',
                  droite: Text(manquantes > 0 ? '$manquantes obligatoire(s) manquante(s)' : '$nb sur ${liste.length}',
                      style: TextStyle(
                          fontSize: 12, color: manquantes > 0 ? Couleurs.attente : (nb == liste.length ? Couleurs.regle : gris)))),
              const SizedBox(height: 8),
              for (final p in liste)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      fournies.contains(p.code)
                          ? const Icon(Icons.check_circle_outline, size: 16, color: Couleurs.regle)
                          : Icon(Icons.circle_outlined, size: 16, color: p.obligatoire ? Couleurs.attente : gris.withValues(alpha: .4)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(p.obligatoire && !fournies.contains(p.code) ? '${p.libelle} (obligatoire)' : p.libelle,
                            style: TextStyle(fontSize: 14, color: fournies.contains(p.code) ? null : gris)),
                      ),
                    ]),
                ),
              if (modifiable) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: mettreAJour,
                    icon: const Icon(Icons.checklist, size: 16),
                    label: const Text('Mettre à jour les pièces'),
                  ),
                ),
              ],
            ]);
          },
        ),
      );
}

// Onglet Contacts --------------------------------------------------------------------

class _OngletContacts extends StatelessWidget {
  const _OngletContacts({required this.eleve, required this.modifiable});

  final Map<String, Object?> eleve;
  final bool modifiable;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final petit = TextStyle(fontSize: 12, height: 1.35, color: gris);
    return Requete(
      '''SELECT ec.*, ct.nom_complet, ct.telephone, ct.profession,
           (SELECT count(*) FROM eleves_contacts x WHERE x.contact_id = ct.id AND x.responsable_financier = 1) AS a_charge
         FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
         WHERE ec.eleve_id = ? ORDER BY ec.tuteur_principal DESC, ec.responsable_financier DESC''',
      parametres: [eleve['id']],
      builder: (context, contacts) => ListView(padding: const EdgeInsets.all(16), children: [
        if (contacts.isEmpty)
          Text('Contacts non visibles sur ce poste, ou aucun parent enregistré.', style: TextStyle(fontSize: 14, color: gris)),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final c in contacts)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: SizedBox(
                  width: 160,
                  child: Column(children: [
                    Initiales('${c['nom_complet']}'.replaceFirst(RegExp(r'^(M\.|Mme|Mlle)\s*', caseSensitive: false), ''),
                        taille: 112),
                    const SizedBox(height: 12),
                    Text('${c['nom_complet']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    Text(liensFamille[c['lien']] ?? '${c['lien']}', style: petit),
                    if (c['telephone'] != null) Text('${c['telephone']}', style: petit),
                    if (c['profession'] != null)
                      Text('${c['profession']}', style: petit, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (c['tuteur_principal'] == 1 || c['responsable_financier'] == 1) ...[
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      if (c['tuteur_principal'] == 1) Text('Tuteur principal', style: petit),
                      if (c['responsable_financier'] == 1)
                        Text('Resp. financier${(c['a_charge'] as int? ?? 0) > 1 ? ' · ${c['a_charge']} enfants' : ''}',
                            style: petit),
                    ],
                    if (modifiable)
                      PopupMenuButton<String>(
                        tooltip: 'Actions',
                        icon: Icon(Icons.more_horiz, size: 18, color: gris),
                        onSelected: (v) => v == 'retirer'
                            ? _supprimer('eleves_contacts', c['id'] as String)
                            : _designerContact(eleve['id'] as String, c['id'] as String, v),
                        itemBuilder: (_) => [
                          if (c['tuteur_principal'] != 1)
                            const PopupMenuItem(value: 'tuteur_principal', child: Text('Faire tuteur principal')),
                          if (c['responsable_financier'] != 1)
                            const PopupMenuItem(value: 'responsable_financier', child: Text('Désigner responsable financier')),
                          if (c['tuteur_principal'] != 1 && c['responsable_financier'] != 1)
                            const PopupMenuItem(value: 'retirer', child: Text('Retirer de la fiche')),
                        ],
                      ),
                  ]),
                ),
              ),
            if (modifiable)
              SizedBox(
                width: 160,
                child: Column(children: [
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _ajouterContactEleve(context, eleve),
                    child: Container(
                      width: 112,
                      height: 112,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Theme.of(context).dividerColor)),
                      child: Icon(Icons.person_add_alt, color: gris),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Ajouter un contact', style: TextStyle(fontSize: 14, color: gris)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

// Onglet Finances --------------------------------------------------------------------

class _OngletFinances extends StatelessWidget {
  const _OngletFinances({required this.espace, required this.eleve, required this.inscription, required this.visible});

  final Espace espace;
  final Map<String, Object?> eleve;
  final Map<String, Object?>? inscription;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    if (!visible) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text("Les finances sont réservées à la caisse et à la direction.", style: TextStyle(fontSize: 14, color: gris)),
      );
    }
    final ins = inscription;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (ins == null)
        Text("Pas d'inscription cette année.", style: TextStyle(fontSize: 14, color: gris))
      else
        _Solde(inscriptionId: ins['id'] as String),
      if (ins != null) ...[
        const SizedBox(height: 20),
        _ArrangementPaiement(espace: espace, inscriptionId: ins['id'] as String),
      ],
      const SizedBox(height: 32),
      _Versements(espace: espace, eleveId: eleve['id'] as String),
      if (ins != null) ...[
        const SizedBox(height: 28),
        _rubrique(context, 'Options et réductions'),
        const SizedBox(height: 4),
        _Souscrire(espace: espace, inscriptionId: ins['id'] as String),
        _Reductions(espace: espace, inscriptionId: ins['id'] as String),
      ],
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => EncaisserScreen(espace: espace, eleveId: eleve['id'] as String))),
          icon: const Icon(Icons.point_of_sale_outlined, size: 15),
          label: const Text('Encaisser'),
        ),
      ),
    ]);
  }
}

/// Reste dû, échéancier en barres, et ce qui est réglé.
class _Solde extends StatelessWidget {
  const _Solde({required this.inscriptionId});

  final String inscriptionId;

  @override
  Widget build(BuildContext context) => Requete(
        // Se recalcule à chaque paiement, souscription ou réduction.
        '''SELECT (SELECT count(*) FROM lignes_encaissement WHERE inscription_id = ?) AS n,
                  (SELECT count(*) FROM encaissements WHERE statut = 'annule') AS a,
                  (SELECT count(*) FROM remboursements WHERE inscription_id = ? AND statut = 'verse') AS v,
                  (SELECT max(updated_at) FROM souscriptions WHERE inscription_id = ?) AS s,
                  (SELECT max(updated_at) FROM reductions_eleves) AS r,
                  (SELECT max(updated_at) FROM frais) AS f''',
        parametres: [inscriptionId, inscriptionId, inscriptionId],
        builder: (context, _) => FutureBuilder(
          future: Future.wait([situationInscription(inscriptionId), reductionsInscription(inscriptionId)]),
          builder: (context, s) {
            if (!s.hasData) return const SizedBox(height: 120);
            final frais = s.data![0] as List<FraisDu>;
            final red = s.data![1] as ({List<Regle> applicables, bool cumul, int plafond});
            final gris = Theme.of(context).colorScheme.onSurfaceVariant;
            final total = frais.fold(0, (x, f) => x + f.total);
            final paye = frais.fold(0, (x, f) => x + f.paye);
            final reste = total - paye;
            final aujourdhui = DateTime.now();
            final tries = [...frais]..sort((a, b) => ordreTypes.indexOf(a.type).compareTo(ordreTypes.indexOf(b.type)));
            final postes = [for (final f in tries) ...f.echeances.map((e) => (frais: f.libelle, e: e))];
            final somme = postes.fold(0, (x, p) => x + p.e.montant);
            if (total == 0) {
              return Text('Aucun frais configuré pour cette classe.', style: TextStyle(fontSize: 14, color: gris));
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Expanded(child: Text('Reste dû', style: TextStyle(fontSize: 14, color: gris))),
                Text(reste <= 0 ? 'À jour' : gnf(reste),
                    style: TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w600, color: reste <= 0 ? Couleurs.regle : Couleurs.retard)),
              ]),
              const SizedBox(height: 16),
              // L'échéancier : le reste au-dessus, la barre, la date limite dessous.
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < postes.length; i++)
                  Expanded(
                    flex: somme == 0 ? 1 : ((postes[i].e.montant / somme) * 1000).round().clamp(1, 1000),
                    child: Padding(
                      padding: EdgeInsets.only(right: i < postes.length - 1 ? 4 : 0),
                      child: Tooltip(
                        message: '${postes[i].frais} · ${postes[i].e.libelle} — ${gnf(postes[i].e.paye)} payés sur '
                            '${gnf(postes[i].e.montant)}',
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text(
                            postes[i].e.soldee ? 'soldé' : _nombre(postes[i].e.reste),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              fontSize: 12,
                              color: postes[i].e.soldee
                                  ? Couleurs.regle
                                  : (postes[i].e.enRetard(aujourdhui) ? Couleurs.retard : null),
                              fontWeight: postes[i].e.enRetard(aujourdhui) ? FontWeight.w500 : null,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              height: 32,
                              child: Stack(fit: StackFit.expand, children: [
                                ColoredBox(
                                    color: postes[i].e.enRetard(aujourdhui) ? Couleurs.retardFond : Couleurs.doux(context)),
                                FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor:
                                      postes[i].e.montant == 0 ? 1 : (postes[i].e.paye / postes[i].e.montant).clamp(0, 1).toDouble(),
                                  child: const ColoredBox(color: Couleurs.regle),
                                ),
                              ]),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${postes[i].e.dateLimite.day.toString().padLeft(2, '0')}/'
                            '${postes[i].e.dateLimite.month.toString().padLeft(2, '0')}',
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: TextStyle(fontSize: 12, color: gris),
                          ),
                        ]),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 16),
              Text(
                '${gnf(paye)} réglés sur ${gnf(total)}'
                '${red.applicables.isEmpty ? '' : ' · réduction ${red.applicables.map((r) => r.libelle).join(', ')}'}',
                style: TextStyle(fontSize: 12, color: gris),
              ),
            ]);
          },
        ),
      );
}

String _nombre(int n) => gnf(n).replaceAll(RegExp(r'\s*GNF$'), '');

/// Versements de l'élève, du plus récent au plus ancien, avec ce que chacun a payé.
class _Versements extends StatelessWidget {
  const _Versements({required this.espace, required this.eleveId});

  final Espace espace;
  final String eleveId;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT l.montant_gnf, f.libelle, e.id, e.numero, e.mode, e.reference, e.date_effective, e.statut, e.created_at
           FROM lignes_encaissement l JOIN encaissements e ON e.id = l.encaissement_id
           LEFT JOIN frais f ON f.id = l.frais_id
           WHERE l.eleve_id = ? ORDER BY e.date_effective DESC, e.created_at DESC''',
        parametres: [eleveId],
        builder: (context, lignes) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final recus = <String, List<Map<String, Object?>>>{};
          for (final l in lignes) {
            recus.putIfAbsent(l['id'] as String, () => []).add(l);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _rubrique(context, 'Versements',
                droite: Text('${recus.length} reçu${recus.length > 1 ? 's' : ''}', style: TextStyle(fontSize: 12, color: gris))),
            const SizedBox(height: 12),
            if (recus.isEmpty) Text('Aucun versement enregistré.', style: TextStyle(fontSize: 14, color: gris)),
            for (final r in recus.values)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => RecuScreen(espace: espace, encaissementId: r.first['id'] as String))),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 3, right: 15),
                      child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle)),
                    ),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(
                              child: Text(_dateLisible(r.first['date_effective']),
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                          Text(gnf(r.fold<int>(0, (s, l) => s + (l['montant_gnf'] as int? ?? 0))),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                decoration: r.first['statut'] == 'annule' ? TextDecoration.lineThrough : null,
                              )),
                        ]),
                        const SizedBox(height: 4),
                        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text('${r.first['numero']}', style: styleMono.copyWith(fontSize: 12, color: gris)),
                          Text('· ${modesPaiement[r.first['mode']] ?? r.first['mode']}', style: TextStyle(fontSize: 12, color: gris)),
                          if (r.first['reference'] != null)
                            Text('· ${r.first['reference']}', style: styleMono.copyWith(fontSize: 12, color: gris)),
                          if (r.first['statut'] == 'annule') const Etat('Annulé', ton: Ton.retard),
                        ]),
                        const SizedBox(height: 8),
                        for (final l in r)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(children: [
                              Expanded(
                                child: Text('${l['libelle'] ?? 'Frais'}',
                                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: gris)),
                              ),
                              Text(_nombre(l['montant_gnf'] as int? ?? 0), style: TextStyle(fontSize: 12, color: gris)),
                            ]),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ),
          ]);
        },
      );
}

// Onglet Suivi -------------------------------------------------------------------------

class _OngletSuivi extends StatelessWidget {
  const _OngletSuivi({required this.eleve});

  final Map<String, Object?> eleve;

  @override
  Widget build(BuildContext context) {
    final e = eleve;
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListView(padding: const EdgeInsets.all(16), children: [
      _rubrique(context, 'Santé'),
      const SizedBox(height: 12),
      if (AlerteSante.concerne(e))
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Couleurs.retardFond,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Couleurs.retard.withValues(alpha: .3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.monitor_heart_outlined, size: 16, color: Couleurs.retard),
              SizedBox(width: 8),
              Text('Alerte santé', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Couleurs.retard)),
            ]),
            const SizedBox(height: 12),
            if (e['sante'] != null) ...[
              Text('Traitement / condition', style: TextStyle(fontSize: 12, color: gris)),
              Text('${e['sante']}', style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
            ],
            if (e['allergies'] != null) ...[
              Text('Allergies', style: TextStyle(fontSize: 12, color: gris)),
              Text('${e['allergies']}', style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
            ],
            if (e['groupe_sanguin'] != null) ...[
              Text('Groupe sanguin', style: TextStyle(fontSize: 12, color: gris)),
              Text('${e['groupe_sanguin']}', style: const TextStyle(fontSize: 14)),
            ],
            Requete(
              '''SELECT ct.nom_complet, ct.telephone FROM eleves_contacts ec JOIN contacts ct ON ct.id = ec.contact_id
                 WHERE ec.eleve_id = ? AND ec.tuteur_principal = 1''',
              parametres: [e['id']],
              builder: (context, t) => t.isEmpty
                  ? const SizedBox.shrink()
                  : Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.only(top: 12),
                      decoration:
                          BoxDecoration(border: Border(top: BorderSide(color: Couleurs.retard.withValues(alpha: .3)))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('À prévenir en urgence', style: TextStyle(fontSize: 12, color: gris)),
                        Wrap(spacing: 12, children: [
                          Text('${t.first['nom_complet']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                          if (t.first['telephone'] != null)
                            Text('${t.first['telephone']}', style: TextStyle(fontSize: 14, color: gris)),
                        ]),
                      ]),
                    ),
            ),
          ]),
        )
      else
        Text(
            'Aucune information de santé signalée'
            '${e['groupe_sanguin'] != null ? ' · groupe ${e['groupe_sanguin']}' : ''}.',
            style: TextStyle(fontSize: 14, color: gris)),
      const SizedBox(height: 28),
      _rubrique(context, 'Historique'),
      const SizedBox(height: 12),
      Requete(
        '''SELECT h.*, cd.nom AS de_classe, cv.nom AS vers_classe, p.nom_complet AS auteur
           FROM historique_eleves h
           LEFT JOIN classes cd ON cd.id = h.de_classe_id
           LEFT JOIN classes cv ON cv.id = h.vers_classe_id
           LEFT JOIN personnel p ON p.user_id = h.par AND p.organisation_id = h.organisation_id
           WHERE h.eleve_id = ? ORDER BY h.quand DESC''',
        parametres: [e['id']],
        builder: (context, h) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (h.isEmpty) Text("L'historique apparaît après la synchronisation.", style: TextStyle(fontSize: 14, color: gris)),
          for (final x in h)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).dividerColor, width: 2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(
                        switch (x['evenement']) {
                          'inscription' => 'Inscription en ${x['vers_classe'] ?? ''}',
                          'mutation' => 'Changement de classe : ${x['de_classe'] ?? '?'} → ${x['vers_classe'] ?? '?'}',
                          _ => '${statutsInscription[x['ancien_statut']] ?? x['ancien_statut']} → '
                              '${statutsInscription[x['nouveau_statut']] ?? x['nouveau_statut']}',
                        },
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
                  Text(_dateLisible(x['quand']), style: styleMono.copyWith(fontSize: 12, color: gris)),
                ]),
                if (x['auteur'] != null) Text('${x['auteur']}', style: TextStyle(fontSize: 12, color: gris)),
                if (x['motif'] != null)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('${x['motif']}', style: const TextStyle(fontSize: 14))),
              ]),
            ),
        ]),
      ),
    ]);
  }
}


// Arrivée en cours d'année et échéancier aménagé --------------------------------------------

/// Ce qui a été convenu avec la famille : arrivée en cours d'année, échéancier
/// aménagé. La direction peut aménager ou revenir au calendrier de l'école.
class _ArrangementPaiement extends StatelessWidget {
  const _ArrangementPaiement({required this.espace, required this.inscriptionId});

  final Espace espace;
  final String inscriptionId;

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT i.*, p.nom_complet AS auteur,
             (SELECT count(*) FROM echeances_eleves e WHERE e.inscription_id = i.id) AS amenagees,
             (SELECT e.motif FROM echeances_eleves e WHERE e.inscription_id = i.id LIMIT 1) AS motif_amenagement
           FROM inscriptions i LEFT JOIN personnel p ON p.user_id = i.cree_par AND p.organisation_id = i.organisation_id
           WHERE i.id = ?''',
        parametres: [inscriptionId],
        builder: (context, l) {
          if (l.isEmpty) return const SizedBox.shrink();
          final i = l.first;
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final direction = espace.gereSite(i['site_id'] as String);
          final amenage = (i['amenagees'] as int? ?? 0) > 0;
          final arrivee = switch (i['arrivee_mode']) {
            'complete' => "Arrivée en cours d'année : année complète",
            'mois' => "Arrivée en cours d'année : paie à partir du mois d'arrivée",
            'negocie' => "Arrivée en cours d'année : montant négocié (− ${gnf(i['arrivee_retrait_gnf'])}) · ${i['arrivee_motif'] ?? ''}",
            _ => null,
          };
          if (arrivee == null && !amenage && !direction) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _rubrique(context, 'Arrangement de paiement'),
            const SizedBox(height: 8),
            if (arrivee != null) Text(arrivee, style: const TextStyle(fontSize: 14)),
            if (amenage)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  const Etat('Échéancier aménagé', ton: Ton.info),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${i['motif_amenagement'] ?? ''}', style: TextStyle(fontSize: 13, color: gris))),
                ]),
              ),
            if (arrivee == null && !amenage) Text("Calendrier de l'école.", style: TextStyle(fontSize: 14, color: gris)),
            if (direction)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: () => _amenager(context, i),
                    icon: const Icon(Icons.edit_calendar_outlined, size: 15),
                    label: Text(amenage ? "Modifier l'échéancier" : "Aménager l'échéancier"),
                  ),
                  if (amenage)
                    TextButton(
                      onPressed: () async {
                        if (await _confirmer(context, "Revenir au calendrier de l'école pour cet élève ?")) {
                          await db.execute('DELETE FROM echeances_eleves WHERE inscription_id = ?', [inscriptionId]);
                        }
                      },
                      child: const Text("Revenir au calendrier de l'école"),
                    ),
                ]),
              ),
          ]);
        },
      );

  /// Aménager l'échéancier de scolarité : dates et découpage, même total.
  Future<void> _amenager(BuildContext context, Map<String, Object?> ins) async {
    final messager = ScaffoldMessenger.of(context);
    final frais = (await situationInscription(inscriptionId)).where((f) => f.type == 'scolarite').toList();
    if (frais.isEmpty) {
      messager.showSnackBar(const SnackBar(content: Text('Aucune scolarité configurée pour cette classe.')));
      return;
    }
    final f = frais.first;
    // On part du calendrier actuel (montants avant réduction : la réduction s'applique ensuite).
    final actuelles = await db.getAll(
        'SELECT libelle, montant_gnf, date_limite FROM echeances_eleves WHERE inscription_id = ? AND frais_id = ? ORDER BY ordre',
        [inscriptionId, f.id]);
    final ecole = await db.getAll('SELECT libelle, montant_gnf, date_limite FROM echeances WHERE frais_id = ? ORDER BY ordre', [f.id]);
    final brut = (await db.get('SELECT montant_gnf FROM frais WHERE id = ?', [f.id]))['montant_gnf'] as int;
    final depart = actuelles.isNotEmpty ? actuelles : ecole;
    final lignes = [
      for (final e in depart)
        (
          libelle: TextEditingController(text: '${e['libelle']}'),
          montant: TextEditingController(text: '${e['montant_gnf']}'),
          date: DateTime.parse('${e['date_limite']}'),
        ),
    ];
    if (lignes.isEmpty) {
      lignes.add((libelle: TextEditingController(text: 'Scolarité'), montant: TextEditingController(text: '$brut'), date: DateTime.now()));
    }
    final dates = [for (final l in lignes) l.date];
    final motif = TextEditingController();
    if (!context.mounted) return;
    int somme() => lignes.fold(0, (s, l) => s + (int.tryParse(l.montant.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0));
    final ok = await _formulaire(context, "Aménager l'échéancier", (maj) => [
          Text('${f.libelle} : ${gnf(brut)} avant réduction. Le total ne change pas ; seules les dates et le découpage changent.',
              style: const TextStyle(fontSize: 13)),
          for (var k = 0; k < lignes.length; k++)
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: lignes[k].libelle, decoration: _champ('Libellé'))),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: lignes[k].montant,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => maj(() {}),
                  decoration: _champ('Montant', suffixe: 'GNF'),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: () async {
                  final d = await _choisirDate(context, dates[k], premier: DateTime(2024), dernier: DateTime(2035));
                  if (d != null) maj(() => dates[k] = d);
                },
                child: Text(_dateLisible(_date(dates[k]))),
              ),
              IconButton(
                tooltip: 'Retirer',
                icon: const Icon(Icons.close, size: 16),
                onPressed: lignes.length <= 1
                    ? null
                    : () => maj(() {
                          lignes.removeAt(k);
                          dates.removeAt(k);
                        }),
              ),
            ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => maj(() {
                lignes.add((
                  libelle: TextEditingController(text: 'Échéance ${lignes.length + 1}'),
                  montant: TextEditingController(text: '${brut - somme() > 0 ? brut - somme() : 0}'),
                  date: dates.last.add(const Duration(days: 30)),
                ));
                dates.add(dates.last.add(const Duration(days: 30)));
              }),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Ajouter une échéance'),
            ),
          ),
          Etat(somme() == brut ? 'Total : ${gnf(somme())}' : 'Total : ${gnf(somme())} au lieu de ${gnf(brut)}',
              ton: somme() == brut ? Ton.regle : Ton.retard),
          TextField(controller: motif, decoration: _champ('Motif', aide: 'Par exemple : père payé en fin de mois')),
        ]);
    if (!ok) return;
    if (somme() != brut) {
      messager.showSnackBar(SnackBar(content: Text('Le total doit rester ${gnf(brut)}.')));
      return;
    }
    if (motif.text.trim().length < 3) {
      messager.showSnackBar(const SnackBar(content: Text("Indiquez le motif de l'aménagement.")));
      return;
    }
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      await tx.execute('DELETE FROM echeances_eleves WHERE inscription_id = ? AND frais_id = ?', [inscriptionId, f.id]);
      for (var k = 0; k < lignes.length; k++) {
        await tx.execute(
            'INSERT INTO echeances_eleves (id, organisation_id, inscription_id, frais_id, ordre, libelle, montant_gnf, date_limite, '
            'motif, par, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              ins['organisation_id'], inscriptionId, f.id, k + 1,
              lignes[k].libelle.text.trim().isEmpty ? 'Échéance ${k + 1}' : lignes[k].libelle.text.trim(),
              int.tryParse(lignes[k].montant.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
              _date(dates[k]), motif.text.trim(), monId, m, m,
            ]);
      }
    });
  }
}
