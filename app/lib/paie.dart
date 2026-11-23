part of 'configuration.dart';

/// La fiche complète du personnel, ses statuts, sa rémunération ; la page Paie
/// (paie du mois, avances, taux de l'école). Le serveur (migration 046) applique
/// les mêmes règles : paie préparée, validée (figée), versée personne par personne ;
/// en espèces, le versement et l'avance sortent de la caisse comme une dépense.

/// Qui voit la paie : qui la prépare, la valide ou la verse.
bool gerePaie(Espace e) =>
    e.fondateur || e.droits.contains('preparer_paie') || e.droits.contains('valider_paie') || e.droits.contains('verser_paie');

const statutsPersonnel = {'actif': 'En poste', 'conge': 'En congé', 'suspendu': 'Suspendu', 'sorti': "A quitté l'établissement"};
const contratsPersonnel = {'permanent': 'Permanent', 'vacataire': 'Vacataire', 'stagiaire': 'Stagiaire', 'autre': 'Autre'};
const motifsDepart = {
  'demission': 'Démission',
  'fin_contrat': 'Fin de contrat',
  'licenciement': 'Licenciement',
  'retraite': 'Retraite',
  'deces': 'Décès',
  'autre': 'Autre',
};
const modesRemuneration = {'mensuel': 'Au mois', 'horaire': "À l'heure", 'mixte': 'Mois + heures'};
const modesVersement = {'especes': 'Espèces (caisse)', 'orange_money': 'Orange Money', 'virement': 'Virement'};

String? _texteOuNull(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
int? _entier(TextEditingController c) => int.tryParse(c.text.replaceAll(RegExp(r'[^0-9]'), ''));

// --- La fiche : dossier et statut ----------------------------------------------------------

extension on String {
  String? ifEmpty() => isEmpty ? null : this;
}

/// Modifier la fiche : nom, téléphone (tant qu'elle n'a pas de compte), état civil, emploi.
Future<void> modifierDossier(BuildContext context, Map<String, Object?> fiche) async {
  TextEditingController ctl(String c) => TextEditingController(text: '${fiche[c] ?? ''}');
  final prenoms = ctl('prenoms'), nom = ctl('nom'), tel = ctl('telephone');
  final compte = fiche['user_id'] != null;
  final lieu = ctl('lieu_naissance'), nationalite = ctl('nationalite'), piece = ctl('piece_identite');
  final tel2 = ctl('telephone2'), adresse = ctl('adresse'), urgence = ctl('contact_urgence'), diplome = ctl('diplome');
  var sexe = '${fiche['sexe'] ?? ''}';
  var contrat = '${fiche['contrat'] ?? ''}';
  DateTime? naissance = DateTime.tryParse('${fiche['date_naissance']}');
  DateTime? embauche = DateTime.tryParse('${fiche['date_embauche']}');
  Widget date(String titre, DateTime? v, ValueChanged<DateTime> change, {required DateTime premier}) => InkWell(
        onTap: () async {
          final d = await _choisirDate(context, v ?? DateTime(2000), premier: premier, dernier: DateTime.now());
          if (d != null) change(d);
        },
        child: InputDecorator(decoration: _champ(titre), child: Text(v == null ? '—' : _dateLisible(_date(v)))),
      );
  final ok = await _formulaire(context, 'Modifier · ${fiche['nom_complet']}', (maj) => [
        TextField(controller: prenoms, textCapitalization: TextCapitalization.words, decoration: _champ('Prénom(s)')),
        TextField(controller: nom, textCapitalization: TextCapitalization.characters, decoration: _champ('Nom')),
        TextField(
            controller: tel,
            enabled: !compte,
            keyboardType: TextInputType.phone,
            decoration: _champ('Téléphone', aide: compte ? 'Relié à son compte : il ne se change pas ici.' : null)),
        Row(children: [
          Expanded(child: _liste('Sexe', sexe, const {'': '—', 'M': 'Homme', 'F': 'Femme'}, (v) => maj(() => sexe = v))),
          const SizedBox(width: 12),
          Expanded(child: date('Date de naissance', naissance, (d) => maj(() => naissance = d), premier: DateTime(1940))),
        ]),
        TextField(controller: lieu, decoration: _champ('Lieu de naissance')),
        Row(children: [
          Expanded(child: TextField(controller: nationalite, decoration: _champ('Nationalité'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: piece, decoration: _champ("N° de pièce d'identité"))),
        ]),
        TextField(controller: tel2, keyboardType: TextInputType.phone, decoration: _champ('2e téléphone')),
        TextField(controller: adresse, decoration: _champ('Adresse (quartier, commune)')),
        TextField(controller: urgence, decoration: _champ('Personne à prévenir', aide: 'Nom et téléphone')),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: date("Date d'embauche", embauche, (d) => maj(() => embauche = d), premier: DateTime(1970))),
          const SizedBox(width: 12),
          Expanded(
              child: _liste('Contrat', contrat, {'': '—', ...contratsPersonnel}, (v) => maj(() => contrat = v))),
        ]),
        TextField(controller: diplome, decoration: _champ('Diplôme ou qualification')),
      ]);
  if (!ok) return;
  if (prenoms.text.trim().isEmpty || nom.text.trim().isEmpty) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Le prénom et le nom sont demandés.')));
    return;
  }
  final t1 = _texteOuNull(tel);
  if (!compte && t1 != null && !RegExp(r'^\+?[0-9 ]{8,20}$').hasMatch(t1)) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Téléphone incorrect.')));
    return;
  }
  final t2 = _texteOuNull(tel2);
  if (t2 != null && !RegExp(r'^\+?[0-9 ]{8,20}$').hasMatch(t2)) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('2e téléphone incorrect.')));
    return;
  }
  await _modifier('personnel', fiche['id'] as String, {
    'prenoms': prenoms.text.trim(),
    'nom': nom.text.trim().toUpperCase(),
    'nom_complet': nomPersonne(prenoms.text, nom.text),
    if (!compte) 'telephone': t1 == null ? null : numeroInternational(t1),
    'sexe': sexe.isEmpty ? null : sexe,
    'date_naissance': naissance == null ? null : _date(naissance!),
    'lieu_naissance': _texteOuNull(lieu),
    'nationalite': _texteOuNull(nationalite),
    'piece_identite': _texteOuNull(piece),
    'telephone2': t2,
    'adresse': _texteOuNull(adresse),
    'contact_urgence': _texteOuNull(urgence),
    'date_embauche': embauche == null ? null : _date(embauche!),
    'contrat': contrat.isEmpty ? null : contrat,
    'diplome': _texteOuNull(diplome),
  });
}

/// Changer le statut : en poste, en congé (du… au…), suspendu, parti (date et motif).
/// En congé ou suspendu, l'accès à l'app est coupé ; au départ, ses enseignements s'arrêtent.
Future<void> changerStatut(BuildContext context, Espace espace, Map<String, Object?> fiche) async {
  var statut = '${fiche['statut'] ?? 'actif'}';
  var depuis = DateTime.tryParse('${fiche['statut_depuis']}') ?? DateTime.now();
  DateTime? jusquAu = DateTime.tryParse('${fiche['statut_jusqu_au']}');
  var motif = '${fiche['motif_depart'] ?? 'demission'}';
  Widget date(String titre, DateTime? v, ValueChanged<DateTime> change) => InkWell(
        onTap: () async {
          final d = await _choisirDate(context, v ?? DateTime.now(), premier: DateTime(DateTime.now().year - 2), dernier: DateTime(DateTime.now().year + 2));
          if (d != null) change(d);
        },
        child: InputDecorator(decoration: _champ(titre), child: Text(v == null ? '—' : _dateLisible(_date(v)))),
      );
  final ok = await _formulaire(context, 'Statut · ${fiche['nom_complet']}', (maj) => [
        _liste('Statut', statut, statutsPersonnel, (v) => maj(() => statut = v)),
        if (statut != 'actif') date(statut == 'sorti' ? 'Date du départ' : 'Depuis le', depuis, (d) => maj(() => depuis = d)),
        if (statut == 'conge') date("Jusqu'au (prévu)", jusquAu, (d) => maj(() => jusquAu = d)),
        if (statut == 'sorti') _liste('Motif du départ', motif, motifsDepart, (v) => maj(() => motif = v)),
        const SizedBox(height: 6),
        Text(
            switch (statut) {
              'conge' => "Son accès à l'app est suspendu pendant le congé. Ses enseignements restent à son nom : "
                  'ajoutez un remplaçant temporaire (Enseignants par classe).',
              'suspendu' => "Son accès à l'app est suspendu.",
              'sorti' => "Son accès à l'app est coupé et ses enseignements s'arrêtent à cette date. La fiche est conservée.",
              _ => "La personne retrouve son accès à l'app.",
            },
            style: const TextStyle(fontSize: 13)),
      ]);
  if (!ok) return;
  await _modifier('personnel', fiche['id'] as String, {
    'statut': statut,
    'statut_depuis': statut == 'actif' ? null : _date(depuis),
    'statut_jusqu_au': statut == 'conge' && jusquAu != null ? _date(jusquAu!) : null,
    'motif_depart': statut == 'sorti' ? motif : null,
  });
  if (statut == 'sorti' && context.mounted) await _apresDepart(context, espace, fiche['id'] as String, _date(depuis));
}

/// Au départ : ses enseignements s'arrêtent ; on dit ce qui reste sans enseignant et l'avance non remboursée.
Future<void> _apresDepart(BuildContext context, Espace espace, String ficheId, String jour) async {
  final siens = await db.getAll(
      '''SELECT ens.id, c.nom AS classe, m.nom AS matiere FROM enseignements ens
           JOIN classes c ON c.id = ens.classe_id JOIN matieres m ON m.id = ens.matiere_id
         WHERE ens.personnel_id = ? AND (ens.fin IS NULL OR ens.fin > ?)''',
      [ficheId, jour]);
  for (final e in siens) {
    await _modifier('enseignements', e['id'] as String, {'fin': jour});
  }
  final avances = await db.getAll('SELECT id, montant_gnf AS montant, mensualites, date_avance AS date FROM avances WHERE personnel_id = ?', [ficheId]);
  final retenu = (await db.get(
      '''SELECT coalesce(sum(l.retenue_avance_gnf), 0) AS n FROM lignes_paie l JOIN paies p ON p.id = l.paie_id
         WHERE l.personnel_id = ? AND p.statut = 'validee' ''', [ficheId]))['n'] as int? ?? 0;
  final reste = restesAvances([
    for (final a in avances) (id: a['id'] as String, montant: a['montant'] as int, mensualites: a['mensualites'] as int, date: '${a['date']}'),
  ], retenu)
      .values
      .fold(0, (s, x) => s + x);
  if ((siens.isEmpty && reste == 0) || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('À régler'),
      content: Text([
        if (siens.isNotEmpty)
          "Ces matières n'ont plus d'enseignant :\n${siens.map((e) => '${e['matiere']} en ${e['classe']}').join('\n')}\n"
              'Affectez-les dans Paramètres › Enseignants par classe.',
        if (reste > 0) 'Avance non remboursée : ${gnf(reste)} restent dus.',
      ].join('\n\n')),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
    ),
  );
}

// --- La fiche : rémunération (confidentielle) ----------------------------------------------

class RemunerationFiche extends StatelessWidget {
  const RemunerationFiche({super.key, required this.espace, required this.fiche});

  final Espace espace;
  final Map<String, Object?> fiche;

  bool get _modifie => espace.fondateur || espace.droits.contains('preparer_paie') || espace.droits.contains('valider_paie');

  @override
  Widget build(BuildContext context) => Requete(
        '''SELECT (SELECT mode FROM remunerations WHERE personnel_id = ?1) AS mode,
                  (SELECT salaire_mensuel_gnf FROM remunerations WHERE personnel_id = ?1) AS salaire,
                  (SELECT group_concat(cycle || ':' || taux_gnf, ';') FROM taux_horaires WHERE personnel_id = ?1) AS taux,
                  (SELECT coalesce(sum(montant_gnf), 0) FROM avances WHERE personnel_id = ?1) AS avances,
                  (SELECT coalesce(sum(l.retenue_avance_gnf), 0) FROM lignes_paie l JOIN paies p ON p.id = l.paie_id
                    WHERE l.personnel_id = ?1 AND p.statut = 'validee') AS retenu''',
        parametres: [fiche['id']],
        builder: (context, l) {
          final r = l.first;
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final taux = '${r['taux'] ?? ''}'.split(';').where((x) => x.contains(':')).map((x) {
            final p = x.split(':');
            return '${nomsCycles[p[0]] ?? p[0]} : ${gnf(int.tryParse(p[1]) ?? 0)}/h';
          }).toList();
          final resteAvance = (r['avances'] as int? ?? 0) - (r['retenu'] as int? ?? 0);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('RÉMUNÉRATION (CONFIDENTIEL)', style: TextStyle(fontSize: 12, letterSpacing: .6, color: gris))),
              if (_modifie)
                TextButton.icon(
                  onPressed: () => modifierRemuneration(context, espace, fiche),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(r['mode'] == null ? 'Régler' : 'Modifier'),
                ),
            ]),
            Card(
              child: ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: Text(r['mode'] == null
                    ? 'Pas encore réglée'
                    : [
                        modesRemuneration[r['mode']] ?? '${r['mode']}',
                        if (r['salaire'] != null && r['mode'] != 'horaire') gnf(r['salaire']),
                      ].join(' · ')),
                subtitle: Text([
                  if (taux.isNotEmpty && r['mode'] != 'mensuel') taux.join(' · '),
                  if (resteAvance > 0) 'Avance à rembourser : ${gnf(resteAvance)}',
                ].join('\n').ifEmpty() ?? (r['mode'] == null ? 'Au mois ou à l\'heure : à régler avant la paie.' : '')),
              ),
            ),
          ]);
        },
      );
}

/// Régler la rémunération : au mois (salaire), à l'heure (taux par cycle), ou les deux.
Future<void> modifierRemuneration(BuildContext context, Espace espace, Map<String, Object?> fiche) async {
  final id = fiche['id'] as String;
  final r = await db.getOptional('SELECT * FROM remunerations WHERE personnel_id = ?', [id]);
  final taux = {for (final t in await db.getAll('SELECT * FROM taux_horaires WHERE personnel_id = ?', [id])) '${t['cycle']}': t};
  final grille = {for (final g in await db.getAll('SELECT * FROM grille_taux WHERE organisation_id = ?', [espace.orgId])) '${g['cycle']}': g['taux_gnf']};
  final cycles = [for (final c in await db.getAll('SELECT DISTINCT cycle FROM niveaux WHERE organisation_id = ? ORDER BY ordre', [espace.orgId])) '${c['cycle']}'];
  // Le mode proposé selon ce qu'il enseigne : primaire, maternelle au mois ; collège, lycée à l'heure.
  final cyclesEnseignes = {
    for (final c in await db.getAll(
        '''SELECT DISTINCT n.cycle FROM enseignements ens JOIN classes c ON c.id = ens.classe_id JOIN niveaux n ON n.id = c.niveau_id
           WHERE ens.personnel_id = ?''', [id]))
      '${c['cycle']}',
  };
  final parHeure = cyclesEnseignes.any((c) => c != 'primaire' && c != 'maternelle');
  var mode = '${r?['mode'] ?? (parHeure ? 'horaire' : 'mensuel')}';
  final salaire = TextEditingController(text: '${r?['salaire_mensuel_gnf'] ?? ''}');
  final champsTaux = {
    for (final c in cycles) c: TextEditingController(text: '${taux[c]?['taux_gnf'] ?? (cyclesEnseignes.contains(c) ? grille[c] ?? '' : '')}'),
  };
  if (!context.mounted) return;
  final ok = await _formulaire(context, 'Rémunération · ${fiche['nom_complet']}', (maj) => [
        _liste('Payé', mode, modesRemuneration, (v) => maj(() => mode = v)),
        if (mode != 'horaire')
          TextField(controller: salaire, keyboardType: TextInputType.number, decoration: _champ('Salaire mensuel (GNF)')),
        if (mode != 'mensuel') ...[
          const SizedBox(height: 4),
          const Text("Taux de l'heure par cycle (GNF) : la grille de l'école est proposée.", style: TextStyle(fontSize: 13)),
          for (final c in cycles)
            TextField(
              controller: champsTaux[c],
              keyboardType: TextInputType.number,
              decoration: _champ('${nomsCycles[c] ?? c}${cyclesEnseignes.contains(c) ? ' (il y enseigne)' : ''}'),
            ),
          const Text('Les heures par semaine se notent sur chaque enseignement (bloc Enseignements).', style: TextStyle(fontSize: 12)),
        ],
      ]);
  if (!ok) return;
  final m0 = _maintenant();
  await db.writeTransaction((tx) async {
    final s = mode == 'horaire' ? null : _entier(salaire);
    if (r == null) {
      await tx.execute(
          'INSERT INTO remunerations (id, organisation_id, personnel_id, mode, salaire_mensuel_gnf, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
          [espace.orgId, id, mode, s, m0, m0]);
    } else {
      await tx.execute('UPDATE remunerations SET mode = ?, salaire_mensuel_gnf = ?, updated_at = ? WHERE id = ?', [mode, s, m0, r['id']]);
    }
    for (final c in cycles) {
      final v = mode == 'mensuel' ? null : _entier(champsTaux[c]!);
      final existant = taux[c];
      if (v == null) {
        if (existant != null) await tx.execute('DELETE FROM taux_horaires WHERE id = ?', [existant['id']]);
      } else if (existant == null) {
        await tx.execute(
            'INSERT INTO taux_horaires (id, organisation_id, personnel_id, cycle, taux_gnf, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
            [espace.orgId, id, c, v, m0, m0]);
      } else {
        await tx.execute('UPDATE taux_horaires SET taux_gnf = ?, updated_at = ? WHERE id = ?', [v, m0, existant['id']]);
      }
    }
  });
}

// --- La page Paie ------------------------------------------------------------------------

enum _OngletPaie { mois, avances, taux }

class PaieScreen extends StatefulWidget {
  const PaieScreen({super.key, required this.espace});

  final Espace espace;

  @override
  State<PaieScreen> createState() => _PaieScreenState();
}

class _PaieScreenState extends State<PaieScreen> {
  _OngletPaie _onglet = _OngletPaie.mois;
  DateTime _mois = DateTime(DateTime.now().year, DateTime.now().month, 1);

  Espace get _e => widget.espace;
  bool get _prepare => _e.fondateur || _e.droits.contains('preparer_paie');
  bool get _valide => _e.fondateur || _e.droits.contains('valider_paie');
  bool get _verse => _e.fondateur || _e.droits.contains('verser_paie');
  String get _moisIso => _date(_mois);
  String get _moisLisible => '${_moisNoms[_mois.month - 1]} ${_mois.year}';

  @override
  Widget build(BuildContext context) {
    final telephone = MediaQuery.sizeOf(context).width < 640;
    return Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
            EnTetePage(titre: 'Paie', sousTitre: 'confidentiel : seuls ceux qui préparent, valident ou versent la paie la voient'),
            const SizedBox(height: 12),
            Segments<_OngletPaie>(
              valeur: _onglet,
              choix: const {_OngletPaie.mois: 'Paie du mois', _OngletPaie.avances: 'Avances', _OngletPaie.taux: "Taux de l'école"},
              onChanged: (v) => setState(() => _onglet = v),
            ),
            const SizedBox(height: 14),
            switch (_onglet) {
              _OngletPaie.mois => _paieDuMois(context),
              _OngletPaie.avances => _avances(context),
              _OngletPaie.taux => _taux(context),
            },
          ]),
        ),
      ),
    );
  }

  // --- Paie du mois -------------------------------------------------------------------

  Widget _paieDuMois(BuildContext context) => Requete(
        'SELECT * FROM paies WHERE organisation_id = ? AND mois = ?',
        parametres: [_e.orgId, _moisIso],
        builder: (context, paies) {
          final paie = paies.firstOrNull;
          final nav = Row(children: [
            IconButton(
                tooltip: 'Mois précédent',
                onPressed: () => setState(() => _mois = DateTime(_mois.year, _mois.month - 1, 1)),
                icon: const Icon(Icons.chevron_left)),
            Text('Paie de ${_moisLisible}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            IconButton(
                tooltip: 'Mois suivant',
                onPressed: () => setState(() => _mois = DateTime(_mois.year, _mois.month + 1, 1)),
                icon: const Icon(Icons.chevron_right)),
          ]);
          if (paie == null) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              nav,
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text("La paie de $_moisLisible n'est pas encore préparée.", style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    const Text("L'app calcule chaque personne en poste : le salaire du mois, les heures prévues (heures par semaine × 4) "
                        "au taux de chaque cycle, et la retenue d'avance. Vous corrigez ensuite les heures réellement faites, les primes et les retenues."),
                    const SizedBox(height: 12),
                    if (_prepare)
                      FilledButton.icon(
                        onPressed: () => _preparer(null),
                        icon: const Icon(Icons.calculate_outlined, size: 18),
                        label: Text('Préparer la paie de $_moisLisible'),
                      )
                    else
                      const Text('Le droit « Préparer la paie » est nécessaire.'),
                  ]),
                ),
              ),
            ]);
          }
          return Requete(
            '''SELECT l.*, p.nom_complet AS nom,
                 (SELECT group_concat(coalesce(a.libelle, a.fonction), ', ') FROM affectations a WHERE a.personnel_id = p.id AND a.actif = 1) AS fonctions
               FROM lignes_paie l JOIN personnel p ON p.id = l.personnel_id WHERE l.paie_id = ? ORDER BY p.nom_complet''',
            parametres: [paie['id']],
            builder: (context, lignes) => _tableauPaie(context, paie, lignes, nav),
          );
        },
      );

  Widget _tableauPaie(BuildContext context, Map<String, Object?> paie, Lignes lignes, Widget nav) {
    final gris = Theme.of(context).colorScheme.onSurfaceVariant;
    final validee = paie['statut'] == 'validee';
    int somme(String c) => lignes.fold(0, (s, l) => s + (l[c] as int? ?? 0));
    final brut = somme('salaire_gnf') + somme('heures_gnf') + somme('primes_gnf');
    final versees = lignes.where((l) => l['versee_le'] != null).length;
    Widget chiffre(String titre, String valeur, {Color? couleur}) => Container(
          width: 190,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(titre, style: TextStyle(fontSize: 12, color: gris)),
            Text(valeur, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: couleur)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        nav,
        validee
            ? Etat('Validée le ${_dateLisible(paie['validee_le']).isEmpty ? '' : _dateLisible(paie['validee_le']).substring(0, 5)}',
                ton: Ton.regle, icone: Icons.verified_outlined)
            : const Etat('En préparation', ton: Ton.attente),
        if (!validee && _prepare)
          OutlinedButton.icon(
            onPressed: () => _preparer(paie),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Recalculer'),
          ),
        if (!validee && _valide)
          FilledButton.icon(
            onPressed: () async {
              if (await _confirmer(context,
                  'Valider la paie de $_moisLisible (${gnf(somme('net_gnf'))} à verser) ? Les montants seront figés ; ils pourront ensuite être versés.')) {
                await _modifier('paies', paie['id'] as String, {'statut': 'validee'});
              }
            },
            icon: const Icon(Icons.verified_outlined, size: 16),
            label: const Text('Valider la paie'),
          ),
        if (validee && _valide && versees == 0)
          TextButton(
            onPressed: () async {
              if (await _confirmer(context, 'Rouvrir la paie de $_moisLisible pour la corriger ?')) {
                await _modifier('paies', paie['id'] as String, {'statut': 'preparation'});
              }
            },
            child: const Text('Rouvrir'),
          ),
        OutlinedButton.icon(
          onPressed: () => _imprimerEtat(paie, lignes),
          icon: const Icon(Icons.print_outlined, size: 16),
          label: const Text('État de paie'),
        ),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        chiffre('Brut', gnf(brut)),
        chiffre('Retenues et avances', gnf(somme('retenues_gnf') + somme('retenue_avance_gnf'))),
        chiffre('Net à verser', gnf(somme('net_gnf'))),
        chiffre('Versés', '$versees / ${lignes.length}', couleur: versees == lignes.length && lignes.isNotEmpty ? Couleurs.regle : null),
      ]),
      const SizedBox(height: 12),
      Tableau(
        colonnes: const [
          ColonneTableau('Personne', flex: 3),
          ColonneTableau('Mode', largeur: 110),
          ColonneTableau('Brut', largeur: 130, droite: true),
          ColonneTableau('Retenues', largeur: 120, droite: true),
          ColonneTableau('Net', largeur: 130, droite: true),
          ColonneTableau('Versement', largeur: 200),
        ],
        lignes: [
          for (final l in lignes)
            [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['nom']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                if (l['fonctions'] != null) Text('${l['fonctions']}', style: TextStyle(fontSize: 12, color: gris)),
              ]),
              Text(modesRemuneration[l['mode']] ?? '${l['mode']}'),
              Text(gnf((l['salaire_gnf'] as int? ?? 0) + (l['heures_gnf'] as int? ?? 0) + (l['primes_gnf'] as int? ?? 0))),
              Text(gnf((l['retenues_gnf'] as int? ?? 0) + (l['retenue_avance_gnf'] as int? ?? 0))),
              Text(gnf(l['net_gnf']), style: const TextStyle(fontWeight: FontWeight.w700)),
              l['versee_le'] != null
                  ? Text('${_dateLisible(l['versee_le']).substring(0, 5)} · ${modesVersement[l['versement_mode']]?.split(' ').first ?? ''}',
                      style: const TextStyle(color: Couleurs.regle))
                  : validee && _verse
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonal(onPressed: () => _verser(l), child: const Text('Verser')),
                        )
                      : Text(validee ? 'à verser' : '—', style: TextStyle(color: gris)),
            ],
        ],
        onTap: (i) => _ouvrirLigne(paie, lignes[i]),
        vide: 'Personne à payer : réglez la rémunération sur les fiches du personnel.',
      ),
      const SizedBox(height: 8),
      Text(
          validee
              ? 'Touchez une ligne pour sa fiche de paie. En espèces, le versement sort de votre caisse (Dépenses › Salaires).'
              : 'Touchez une ligne pour corriger les heures réellement faites, ajouter une prime ou une retenue.',
          style: TextStyle(fontSize: 12, color: gris)),
    ]);
  }

  /// Préparer (ou recalculer) la paie du mois. Un recalcul garde les heures
  /// corrigées, les primes et les retenues déjà saisies.
  Future<void> _preparer(Map<String, Object?>? paie) async {
    final messager = ScaffoldMessenger.of(context);
    final debutMois = _moisIso, finMois = _date(DateTime(_mois.year, _mois.month + 1, 0));
    final personnes = await db.getAll(
        '''SELECT p.id, p.nom_complet, r.mode, r.salaire_mensuel_gnf AS salaire FROM personnel p JOIN remunerations r ON r.personnel_id = p.id
           WHERE p.organisation_id = ? AND p.statut IN ('actif', 'conge') ORDER BY p.nom_complet''',
        [_e.orgId]);
    final sansRemuneration = (await db.get(
        '''SELECT count(*) AS n FROM personnel p WHERE p.organisation_id = ? AND p.statut IN ('actif', 'conge')
             AND NOT EXISTS (SELECT 1 FROM remunerations r WHERE r.personnel_id = p.id)''', [_e.orgId]))['n'] as int? ?? 0;
    final grille = {for (final g in await db.getAll('SELECT cycle, taux_gnf FROM grille_taux WHERE organisation_id = ?', [_e.orgId])) '${g['cycle']}': g['taux_gnf'] as int};
    final anciennes = paie == null
        ? <String, Map<String, Object?>>{}
        : {for (final l in await db.getAll('SELECT * FROM lignes_paie WHERE paie_id = ?', [paie['id']])) l['personnel_id'] as String: l};
    final m0 = _maintenant();
    var n = 0;
    await db.writeTransaction((tx) async {
      final paieId = paie?['id'] as String? ?? (await tx.get('SELECT uuid() AS id'))['id'] as String;
      if (paie == null) {
        await tx.execute('INSERT INTO paies (id, organisation_id, mois, statut, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
            [paieId, _e.orgId, debutMois, 'preparation', m0, m0]);
      }
      for (final p in personnes) {
        final id = p['id'] as String;
        final mode = '${p['mode']}';
        final salaire = mode == 'horaire' ? 0 : (p['salaire'] as int? ?? 0);
        final taux = {for (final t in await tx.getAll('SELECT cycle, taux_gnf FROM taux_horaires WHERE personnel_id = ?', [id])) '${t['cycle']}': t['taux_gnf'] as int};
        final ancienne = anciennes[id];
        final corrections = <String, LigneHeures>{
          if (ancienne?['detail'] != null)
            for (final j in (jsonDecode('${ancienne!['detail']}') as List).cast<Map<String, Object?>>())
              '${j['classe']}|${j['matiere']}': LigneHeures.depuisJson(j),
        };
        final heures = <LigneHeures>[
          if (mode != 'mensuel')
            for (final e in await tx.getAll(
                '''SELECT c.nom AS classe, m.nom AS matiere, n.cycle, ens.heures_semaine FROM enseignements ens
                     JOIN classes c ON c.id = ens.classe_id JOIN matieres m ON m.id = ens.matiere_id JOIN niveaux n ON n.id = c.niveau_id
                   WHERE ens.personnel_id = ? AND ens.heures_semaine IS NOT NULL AND ens.debut <= ? AND (ens.fin IS NULL OR ens.fin >= ?)
                   ORDER BY n.ordre, c.nom, m.nom''',
                [id, finMois, debutMois]))
              Builder2.ligne(e, taux[e['cycle']] ?? grille[e['cycle']] ?? 0, corrections['${e['classe']}|${e['matiere']}']),
        ];
        final montant = montantHeures(heures);
        // L'avance : une mensualité de chaque avance en cours, plafonnée à la moitié du brut.
        final avances = [
          for (final a in await tx.getAll('SELECT id, montant_gnf, mensualites, date_avance FROM avances WHERE personnel_id = ? AND date_avance <= ?', [id, finMois]))
            (id: a['id'] as String, montant: a['montant_gnf'] as int, mensualites: a['mensualites'] as int, date: '${a['date_avance']}'),
        ];
        final dejaRetenu = (await tx.get(
            '''SELECT coalesce(sum(l.retenue_avance_gnf), 0) AS n FROM lignes_paie l JOIN paies pa ON pa.id = l.paie_id
               WHERE l.personnel_id = ? AND pa.id <> ?''', [id, paieId]))['n'] as int? ?? 0;
        final primes = ancienne?['primes_gnf'] as int? ?? 0;
        // Les retenues ne dépassent jamais le brut (le net reste ≥ 0).
        final retenues = math.min(ancienne?['retenues_gnf'] as int? ?? 0, salaire + montant + primes);
        final brut = salaire + montant + primes - retenues;
        final proposee = retenueProposee(avances, dejaRetenu, plafond: brut ~/ 2);
        final calcul = netAPayer(salaire: salaire, heures: montant, primes: primes, retenues: retenues, retenueAvance: proposee);
        final valeurs = [mode, salaire, montant, heures.isEmpty ? null : jsonEncode([for (final h in heures) h.versJson()]), primes, retenues,
          calcul.retenueAvance, calcul.net];
        if (ancienne == null) {
          await tx.execute(
              '''INSERT INTO lignes_paie (id, organisation_id, paie_id, personnel_id, mode, salaire_gnf, heures_gnf, detail, primes_gnf, retenues_gnf,
                   retenue_avance_gnf, net_gnf, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
              [_e.orgId, paieId, id, ...valeurs, m0, m0]);
        } else {
          await tx.execute(
              '''UPDATE lignes_paie SET mode = ?, salaire_gnf = ?, heures_gnf = ?, detail = ?, primes_gnf = ?, retenues_gnf = ?,
                   retenue_avance_gnf = ?, net_gnf = ?, updated_at = ? WHERE id = ?''',
              [...valeurs, m0, ancienne['id']]);
        }
        n++;
      }
    });
    messager.showSnackBar(SnackBar(
        content: Text('$n personne(s) calculée(s).${sansRemuneration > 0 ? ' $sansRemuneration sans rémunération réglée (fiche du personnel).' : ''}')));
  }

  /// Corriger une ligne (en préparation) ou imprimer sa fiche de paie.
  Future<void> _ouvrirLigne(Map<String, Object?> paie, Map<String, Object?> l) async {
    if (paie['statut'] == 'validee' || !_prepare) {
      await _fichePaie(l);
      return;
    }
    final heures = l['detail'] == null
        ? <LigneHeures>[]
        : [for (final j in (jsonDecode('${l['detail']}') as List).cast<Map<String, Object?>>()) LigneHeures.depuisJson(j)];
    final champsHeures = [for (final h in heures) TextEditingController(text: noteLisible(h.heuresPayees).replaceAll(',00', ''))];
    final motifsHeures = [for (final h in heures) TextEditingController(text: h.motif ?? '')];
    final primes = TextEditingController(text: '${l['primes_gnf'] ?? 0}');
    final retenues = TextEditingController(text: '${l['retenues_gnf'] ?? 0}');
    final avance = TextEditingController(text: '${l['retenue_avance_gnf'] ?? 0}');
    final notes = TextEditingController(text: '${l['notes'] ?? ''}');
    final ok = await _formulaire(context, '${l['nom']} · $_moisLisible', (maj) => [
          if ((l['salaire_gnf'] as int? ?? 0) > 0) Text('Salaire du mois : ${gnf(l['salaire_gnf'])}', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (heures.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('Heures réellement enseignées (prévues : heures par semaine × 4)', style: TextStyle(fontWeight: FontWeight.w600)),
            for (var i = 0; i < heures.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: Text('${heures[i].classe} · ${heures[i].matiere}\nprévues ${noteLisible(heures[i].heuresPrevues).replaceAll(',00', '')} h · '
                        '${gnf(heures[i].taux)}/h', style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                      width: 80,
                      child: TextField(
                          controller: champsHeures[i],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: _champ('Faites'))),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: TextField(controller: motifsHeures[i], decoration: _champ('Motif (absence…)'))),
                ]),
              ),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: TextField(controller: primes, keyboardType: TextInputType.number, decoration: _champ('Primes (GNF)'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: retenues, keyboardType: TextInputType.number, decoration: _champ('Retenues (GNF)'))),
          ]),
          TextField(controller: avance, keyboardType: TextInputType.number, decoration: _champ("Retenue sur avance (GNF)", aide: 'Proposée : une mensualité')),
          TextField(controller: notes, decoration: _champ('Motifs (prime, retenue, avance décalée…)')),
        ], valider: () => 'Enregistrer');
    if (!ok) return;
    final corrigees = [
      for (var i = 0; i < heures.length; i++)
        Builder2.corriger(heures[i], double.tryParse(champsHeures[i].text.replaceAll(',', '.')), motifsHeures[i].text.trim()),
    ];
    final salaire = l['salaire_gnf'] as int? ?? 0;
    final p = _entier(primes) ?? 0;
    final r = math.min(_entier(retenues) ?? 0, salaire + montantHeures(corrigees) + p);
    final calcul = netAPayer(salaire: salaire, heures: montantHeures(corrigees), primes: p, retenues: r, retenueAvance: _entier(avance) ?? 0);
    await _modifier('lignes_paie', l['id'] as String, {
      'heures_gnf': montantHeures(corrigees),
      'detail': corrigees.isEmpty ? null : jsonEncode([for (final h in corrigees) h.versJson()]),
      'primes_gnf': p,
      'retenues_gnf': r,
      'retenue_avance_gnf': calcul.retenueAvance,
      'net_gnf': calcul.net,
      'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
    });
  }

  Future<void> _verser(Map<String, Object?> l) async {
    var mode = 'especes';
    final reference = TextEditingController();
    final ok = await _formulaire(context, 'Verser · ${l['nom']}', (maj) => [
          Text('Net à verser : ${gnf(l['net_gnf'])}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _liste('Mode', mode, modesVersement, (v) => maj(() => mode = v)),
          if (mode != 'especes') TextField(controller: reference, decoration: _champ('Référence de la transaction'))
          else const Text("La somme sort de votre caisse (Dépenses › Salaires) : elle entre dans votre clôture du jour.", style: TextStyle(fontSize: 13)),
        ], valider: () => 'Verser');
    if (!ok) return;
    await _modifier('lignes_paie', l['id'] as String, {
      'versement_mode': mode,
      'versement_reference': mode == 'especes' || reference.text.trim().isEmpty ? null : reference.text.trim(),
      'versee_le': _date(DateTime.now()),
    });
  }

  Future<void> _fichePaie(Map<String, Object?> l) async {
    final heures = l['detail'] == null
        ? <LigneHeures>[]
        : [for (final j in (jsonDecode('${l['detail']}') as List).cast<Map<String, Object?>>()) LigneHeures.depuisJson(j)];
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
    final pdf = await fichePaiePdf(
      ecole: Map.of(ecole),
      nom: '${l['nom']}',
      fonction: '${l['fonctions'] ?? ''}',
      mois: _moisLisible,
      lignes: [
        if ((l['salaire_gnf'] as int? ?? 0) > 0) (libelle: 'Salaire du mois', detail: '', montant: l['salaire_gnf'] as int),
        for (final h in heures)
          (
            libelle: '${h.classe} · ${h.matiere}',
            detail: '${noteLisible(h.heuresPayees).replaceAll(',00', '')} h × ${gnf(h.taux)}${h.motif == null ? '' : ' (${h.motif})'}',
            montant: h.montant,
          ),
        if ((l['primes_gnf'] as int? ?? 0) > 0) (libelle: 'Primes', detail: '', montant: l['primes_gnf'] as int),
        if ((l['retenues_gnf'] as int? ?? 0) > 0) (libelle: 'Retenues', detail: '', montant: -(l['retenues_gnf'] as int)),
        if ((l['retenue_avance_gnf'] as int? ?? 0) > 0) (libelle: "Remboursement d'avance", detail: '', montant: -(l['retenue_avance_gnf'] as int)),
      ],
      net: l['net_gnf'] as int? ?? 0,
      versement: l['versee_le'] == null
          ? null
          : 'Versé le ${_dateLisible(l['versee_le'])} · ${modesVersement[l['versement_mode']] ?? ''}'
              '${l['versement_reference'] == null ? '' : ' · réf. ${l['versement_reference']}'}',
      images: await _imagesEcole(_e.orgId),
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Fiche de paie ${l['nom']} $_moisLisible');
  }

  Future<void> _imprimerEtat(Map<String, Object?> paie, Lignes lignes) async {
    final ecole = await db.get('SELECT * FROM organisations WHERE id = ?', [_e.orgId]);
    final pdf = await etatPaiePdf(
      ecole: Map.of(ecole),
      mois: _moisLisible,
      statut: paie['statut'] == 'validee' ? 'Validée le ${_dateLisible(paie['validee_le'])}' : 'En préparation (provisoire)',
      lignes: [
        for (final l in lignes)
          (
            nom: '${l['nom']}',
            mode: modesRemuneration[l['mode']] ?? '',
            brut: (l['salaire_gnf'] as int? ?? 0) + (l['heures_gnf'] as int? ?? 0) + (l['primes_gnf'] as int? ?? 0),
            retenues: (l['retenues_gnf'] as int? ?? 0) + (l['retenue_avance_gnf'] as int? ?? 0),
            net: l['net_gnf'] as int? ?? 0,
            verse: l['versee_le'] == null ? '' : '${_dateLisible(l['versee_le'])} ${modesVersement[l['versement_mode']]?.split(' ').first ?? ''}',
          ),
      ],
      images: await _imagesEcole(_e.orgId),
    );
    await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'État de paie $_moisLisible');
  }

  // --- Avances ------------------------------------------------------------------------

  Widget _avances(BuildContext context) => Requete(
        '''SELECT a.*, p.nom_complet AS nom,
             (SELECT coalesce(sum(l.retenue_avance_gnf), 0) FROM lignes_paie l JOIN paies pa ON pa.id = l.paie_id
               WHERE l.personnel_id = a.personnel_id AND pa.statut = 'validee') AS retenu_personne
           FROM avances a JOIN personnel p ON p.id = a.personnel_id WHERE a.organisation_id = ? ORDER BY a.date_avance DESC, a.created_at DESC''',
        parametres: [_e.orgId],
        builder: (context, avances) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          // Le reste de chaque avance : les retenues validées remboursent d'abord la plus ancienne.
          final parPersonne = <String, List<Map<String, Object?>>>{};
          for (final a in avances) {
            parPersonne.putIfAbsent(a['personnel_id'] as String, () => []).add(a);
          }
          final restes = <String, int>{};
          for (final e in parPersonne.values) {
            restes.addAll(restesAvances([
              for (final a in e) (id: a['id'] as String, montant: a['montant_gnf'] as int, mensualites: a['mensualites'] as int, date: '${a['date_avance']}'),
            ], e.first['retenu_personne'] as int? ?? 0));
          }
          final totalReste = restes.values.fold(0, (s, x) => s + x);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Reste à rembourser : ${gnf(totalReste)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              if (_verse || _valide)
                FilledButton.icon(
                  onPressed: _nouvelleAvance,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Nouvelle avance'),
                ),
            ]),
            const SizedBox(height: 6),
            Text("Retenue chaque mois sur la paie (montant ÷ mensualités), au plus la moitié du brut. En espèces, l'avance sort de la caisse "
                '(Dépenses › Avances sur salaire).', style: TextStyle(fontSize: 12, color: gris)),
            const SizedBox(height: 12),
            Tableau(
              colonnes: const [
                ColonneTableau('Date', largeur: 100),
                ColonneTableau('Personne', flex: 3),
                ColonneTableau('Montant', largeur: 140, droite: true),
                ColonneTableau('Mensualités', largeur: 110, droite: true),
                ColonneTableau('Reste', largeur: 140, droite: true),
                ColonneTableau('Mode', largeur: 130),
              ],
              lignes: [
                for (final a in avances)
                  [
                    Text(_dateLisible(a['date_avance'])),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${a['nom']}'),
                      if (a['motif'] != null) Text('${a['motif']}', style: TextStyle(fontSize: 12, color: gris)),
                    ]),
                    Text(gnf(a['montant_gnf'])),
                    Text('${a['mensualites']} × ${gnf(((a['montant_gnf'] as int) / (a['mensualites'] as int)).ceil())}'),
                    Text((restes[a['id']] ?? 0) == 0 ? 'remboursée' : gnf(restes[a['id']]),
                        style: TextStyle(color: (restes[a['id']] ?? 0) == 0 ? Couleurs.regle : Couleurs.attente, fontWeight: FontWeight.w600)),
                    Text(modesVersement[a['mode']]?.split(' ').first ?? '${a['mode']}'),
                  ],
              ],
              vide: 'Aucune avance.',
            ),
          ]);
        },
      );

  Future<void> _nouvelleAvance() async {
    final personnes = await db.getAll(
        "SELECT id, nom_complet FROM personnel WHERE organisation_id = ? AND statut IN ('actif', 'conge') ORDER BY nom_complet", [_e.orgId]);
    if (personnes.isEmpty || !mounted) return;
    var personne = personnes.first['id'] as String;
    var mode = 'especes';
    var mensualites = 1;
    final montant = TextEditingController(), reference = TextEditingController(), motif = TextEditingController();
    final ok = await _formulaire(context, 'Nouvelle avance', (maj) => [
          _liste('Personne', personne, {for (final p in personnes) p['id'] as String: '${p['nom_complet']}'}, (v) => maj(() => personne = v)),
          TextField(controller: montant, keyboardType: TextInputType.number, decoration: _champ('Montant (GNF)')),
          _liste('Remboursée en', mensualites, {for (var i = 1; i <= 12; i++) i: i == 1 ? '1 mois' : '$i mois'}, (v) => maj(() => mensualites = v)),
          _liste('Versée', mode, modesVersement, (v) => maj(() => mode = v)),
          if (mode != 'especes') TextField(controller: reference, decoration: _champ('Référence de la transaction')),
          TextField(controller: motif, decoration: _champ('Motif (facultatif)')),
          if (mode == 'especes')
            const Text('La somme sort de votre caisse maintenant (Dépenses › Avances sur salaire).', style: TextStyle(fontSize: 13)),
        ], valider: () => "Verser l'avance");
    if (!ok) return;
    final m = _entier(montant);
    if (m == null || m <= 0) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Montant incorrect.')));
      return;
    }
    await _inserer('avances', {
      'organisation_id': _e.orgId,
      'personnel_id': personne,
      'montant_gnf': m,
      'date_avance': _date(DateTime.now()),
      'mensualites': mensualites,
      'mode': mode,
      'reference': mode == 'especes' ? null : _texteOuNull(reference),
      'motif': _texteOuNull(motif),
    });
  }

  // --- Taux de l'école ------------------------------------------------------------------

  Widget _taux(BuildContext context) => Requete(
        '''SELECT n.cycle, min(n.ordre) AS ordre, (SELECT taux_gnf FROM grille_taux g WHERE g.organisation_id = ? AND g.cycle = n.cycle) AS taux,
             (SELECT id FROM grille_taux g WHERE g.organisation_id = ? AND g.cycle = n.cycle) AS id
           FROM niveaux n WHERE n.organisation_id = ? GROUP BY n.cycle ORDER BY ordre''',
        parametres: [_e.orgId, _e.orgId, _e.orgId],
        builder: (context, cycles) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final modifie = _prepare || _valide;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text("Le taux de l'heure proposé pour chaque cycle. Il se règle ensuite personne par personne (fiche du personnel), "
                'puisque les taux se négocient.', style: TextStyle(fontSize: 13, color: gris)),
            const SizedBox(height: 10),
            for (final c in cycles)
              Card(
                child: ListTile(
                  title: Text(nomsCycles[c['cycle']] ?? '${c['cycle']}'),
                  subtitle: Text(c['taux'] == null ? 'Pas de taux' : '${gnf(c['taux'])} de l\'heure'),
                  trailing: modifie ? const Icon(Icons.edit_outlined, size: 18) : null,
                  onTap: modifie
                      ? () async {
                          final champ = TextEditingController(text: '${c['taux'] ?? ''}');
                          final ok = await _formulaire(context, 'Taux · ${nomsCycles[c['cycle']] ?? c['cycle']}',
                              (maj) => [TextField(controller: champ, keyboardType: TextInputType.number, decoration: _champ("Taux de l'heure (GNF)"))]);
                          if (!ok) return;
                          final v = _entier(champ);
                          if (c['id'] == null && v != null) {
                            await _inserer('grille_taux', {'organisation_id': _e.orgId, 'cycle': c['cycle'], 'taux_gnf': v});
                          } else if (c['id'] != null && v != null) {
                            await _modifier('grille_taux', c['id'] as String, {'taux_gnf': v});
                          } else if (c['id'] != null) {
                            await _supprimer('grille_taux', c['id'] as String);
                          }
                        }
                      : null,
                ),
              ),
          ]);
        },
      );
}

/// Petites fabriques de lignes d'heures (lisibles dans les boucles ci-dessus).
abstract final class Builder2 {
  static LigneHeures ligne(Map<String, Object?> e, int taux, LigneHeures? correction) {
    final base = LigneHeures(
      classe: '${e['classe']}',
      matiere: '${e['matiere']}',
      cycle: '${e['cycle']}',
      heuresSemaine: (e['heures_semaine'] as num).toDouble(),
      taux: taux,
    );
    return correction == null ? base : base.avecHeures(correction.heuresFaites, correction.motif);
  }

  static LigneHeures corriger(LigneHeures h, double? faites, String motif) =>
      h.avecHeures(faites == null || faites == h.heuresPrevues ? null : faites, motif.isEmpty ? null : motif);
}
