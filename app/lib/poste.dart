part of 'configuration.dart';

/// Étape 4 de l'onboarding : activer les postes de travail.
/// L'activation (en ligne, une fois) donne au poste son code (A, B, C…) : il
/// fabriquera seul, hors ligne, des numéros uniques (matricules, reçus).
/// Le code PIN, propre à ce poste, rouvre l'app sans réseau.

/// Même numéro que « version » dans pubspec.yaml (un test le vérifie).
const versionApp = '0.9.10';

/// Ce poste, tel qu'enregistré localement (table locale, jamais synchronisée).
Future<Map<String, Object?>?> cePoste() => db.getOptional('SELECT * FROM ce_poste LIMIT 1');

/// Derniers numéros pris par ce poste pour une série (reçus d'un site et d'une
/// année, matricules d'un préfixe) : ajoutés à ceux de la base pour continuer
/// la série, même si la synchro n'a pas encore tout ramené.
Future<List<String>> derniersNumeros(dynamic tx, String cle) async =>
    [for (final r in await tx.getAll('SELECT valeur FROM compteurs_poste WHERE id = ?', [cle])) r['valeur'] as String];

Future<void> noterNumero(dynamic tx, String cle, String valeur) async {
  await tx.execute('DELETE FROM compteurs_poste WHERE id = ?', [cle]);
  await tx.execute('INSERT INTO compteurs_poste (id, valeur) VALUES (?, ?)', [cle, valeur]);
}

/// Choisir (ou rechoisir) le code PIN de ce poste. Vrai s'il est enregistré.
Future<bool> definirPinPoste(BuildContext context) async {
  final a = TextEditingController();
  final b = TextEditingController();
  final ok = await _formulaire(context, 'Code PIN de ce poste', (_) => [
        const Text("Il rouvre l'app après un verrouillage, même sans internet. Ne le donnez qu'aux personnes qui utilisent cet appareil."),
        TextField(
            controller: a,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: _champ('Code PIN (4 à 6 chiffres)')),
        TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: 6, decoration: _champ('Confirmer')),
      ]);
  if (!ok) return false;
  if (!pinValide(a.text) || a.text != b.text) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Code PIN invalide (4 à 6 chiffres) ou les deux codes sont différents.')));
    }
    return false;
  }
  final sel = _nouveauSel();
  await db.execute('UPDATE ce_poste SET pin_empreinte = ?, pin_sel = ?, echecs = 0, attendre_jusqu = NULL', [empreintePin(a.text, sel), sel]);
  return true;
}

const messagePosteEnAttente =
    'Ce poste attend la validation de la direction : il peut consulter, mais pas inscrire ni encaisser.';

/// Vrai si ce poste a été activé par quelqu'un hors direction et n'est pas encore validé.
Future<bool> posteEnAttente() async =>
    (await db.getOptional('SELECT p.statut FROM ce_poste c JOIN postes p ON p.id = c.poste_id'))?['statut'] == 'a_valider';

// Code PIN --------------------------------------------------------------------

/// Empreinte du PIN : salée et répétée, pour qu'on ne puisse pas le retrouver
/// en lisant la base du poste.
String empreintePin(String pin, String sel) {
  List<int> h = utf8.encode('$sel:$pin');
  for (var i = 0; i < 20000; i++) {
    h = sha256.convert(h).bytes;
  }
  return base64Url.encode(h);
}

String _nouveauSel() {
  final r = Random.secure();
  return base64Url.encode(List.generate(16, (_) => r.nextInt(256)));
}

bool pinValide(String pin) => RegExp(r'^[0-9]{4,6}$').hasMatch(pin);

// Activation ------------------------------------------------------------------

class ActiverPosteScreen extends StatefulWidget {
  const ActiverPosteScreen({super.key, required this.orgId});

  final String orgId;

  @override
  State<ActiverPosteScreen> createState() => _ActiverPosteScreenState();
}

class _ActiverPosteScreenState extends State<ActiverPosteScreen> {
  final _nom = TextEditingController(text: switch (defaultTargetPlatform) {
    _ when kIsWeb => 'Navigateur',
    TargetPlatform.android || TargetPlatform.iOS => 'Téléphone',
    _ => 'PC',
  });
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  Map<String?, String> _sites = {};
  String? _site;
  bool _envoi = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _chargerSites();
  }

  /// Sites où je travaille ; « tout le groupe » pour le fondateur.
  Future<void> _chargerSites() async {
    final mes = await db.getAll('SELECT site_id, role FROM rattachements WHERE user_id = ? AND organisation_id = ? AND actif = 1',
        [monId, widget.orgId]);
    final tous = mes.any((r) => r['site_id'] == null);
    final sites = await db.getAll('SELECT id, nom FROM sites WHERE organisation_id = ? ORDER BY created_at', [widget.orgId]);
    setState(() {
      _sites = {
        for (final s in sites)
          if (tous || mes.any((r) => r['site_id'] == s['id'])) s['id'] as String: s['nom'] as String,
        if (mes.any((r) => r['role'] == 'fondateur')) null: 'Tout le groupe (poste du fondateur)',
      };
      _site = _sites.keys.isEmpty ? null : _sites.keys.first;
    });
  }

  Future<void> _activer() async {
    if (_nom.text.trim().length < 2) {
      setState(() => _erreur = 'Donnez un nom au poste.');
      return;
    }
    if (!pinValide(_pin.text)) {
      setState(() => _erreur = 'Le code PIN a 4 à 6 chiffres.');
      return;
    }
    if (_pin.text != _pin2.text) {
      setState(() => _erreur = 'Les deux codes PIN sont différents.');
      return;
    }
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    try {
      final poste = await activerPoste(
        organisation: widget.orgId,
        site: _site,
        nom: _nom.text.trim(),
        plateforme: kIsWeb ? 'web' : defaultTargetPlatform.name,
        version: versionApp,
      );
      final sel = _nouveauSel();
      await db.execute('DELETE FROM ce_poste');
      await db.execute(
          'INSERT INTO ce_poste (id, poste_id, organisation_id, code, nom, pin_empreinte, pin_sel, echecs) '
          'VALUES (uuid(), ?, ?, ?, ?, ?, ?, 0)',
          [poste.id, widget.orgId, poste.code, _nom.text.trim(), empreintePin(_pin.text, sel), sel]);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Poste ${poste.code} activé'),
          content: Text('Ce poste porte la lettre ${poste.code} : elle apparaîtra dans les matricules '
              'et les numéros de reçu créés ici.\n\nRetenez votre code PIN : il rouvre l\'app, même sans internet.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } on PostgrestException catch (e) {
      setState(() => _erreur = e.message);
    } catch (_) {
      setState(() => _erreur = "Il faut internet pour activer le poste. Réessayez une fois connecté.");
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: 'Activer ce poste',
        corps: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('À faire une fois sur chaque appareil, avec internet. '
              'Le poste reçoit une lettre (A, B, C…) qui rend ses numéros uniques, même hors ligne.'),
          const SizedBox(height: 20),
          TextField(controller: _nom, decoration: _champ('Nom du poste', aide: 'Par exemple : PC du secrétariat')),
          const SizedBox(height: 14),
          if (_sites.length > 1) ...[
            _liste('Site', _site, _sites, (v) => setState(() => _site = v)),
            const SizedBox(height: 14),
          ],
          TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: _champ('Code PIN (4 à 6 chiffres)', aide: "Pour rouvrir l'app sur ce poste")),
          const SizedBox(height: 8),
          TextField(
              controller: _pin2,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: _champ('Confirmer le code PIN')),
          if (_erreur != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_erreur!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _envoi || _sites.isEmpty ? null : _activer,
            child: Text(_envoi ? 'Activation…' : 'Activer ce poste'),
          ),
        ]),
      );
}

// Ouverture de l'app : code PIN -----------------------------------------------

/// Si ce poste a un code PIN, on le demande avant d'ouvrir l'accueil.
class PorteDuPoste extends StatelessWidget {
  const PorteDuPoste({super.key, required this.accueil, required this.sortie});

  final Widget accueil;

  /// Écran affiché si la personne choisit de se déconnecter (PIN oublié).
  final Widget sortie;

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: cePoste(),
        builder: (context, s) {
          if (s.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final poste = s.data;
          if (poste == null || poste['pin_empreinte'] == null) return accueil;
          return _PinScreen(poste: poste, accueil: accueil, sortie: sortie);
        },
      );
}

class _PinScreen extends StatefulWidget {
  const _PinScreen({required this.poste, required this.accueil, required this.sortie});

  final Map<String, Object?> poste;
  final Widget accueil;
  final Widget sortie;

  @override
  State<_PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<_PinScreen> {
  final _pin = TextEditingController();
  String? _erreur;

  static const _essaisAvantAttente = 5;

  Future<void> _valider() async {
    final p = await cePoste();
    if (p == null) return;
    final attendre = DateTime.tryParse('${p['attendre_jusqu']}');
    if (attendre != null && DateTime.now().isBefore(attendre)) {
      final min = attendre.difference(DateTime.now()).inMinutes + 1;
      setState(() => _erreur = 'Trop d\'essais. Réessayez dans $min min.');
      return;
    }
    if (empreintePin(_pin.text, p['pin_sel'] as String) == p['pin_empreinte']) {
      await db.execute('UPDATE ce_poste SET echecs = 0, attendre_jusqu = NULL');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => widget.accueil));
      return;
    }
    final echecs = ((p['echecs'] as int?) ?? 0) + 1;
    final bloque = echecs % _essaisAvantAttente == 0;
    await db.execute('UPDATE ce_poste SET echecs = ?, attendre_jusqu = ?', [
      echecs,
      bloque ? DateTime.now().add(Duration(minutes: 5 * (echecs ~/ _essaisAvantAttente))).toIso8601String() : null,
    ]);
    _pin.clear();
    setState(() => _erreur = bloque ? 'Trop d\'essais. Patientez quelques minutes.' : 'Code PIN incorrect.');
  }

  Future<void> _oublie() async {
    final enAttente = (await db.getUploadQueueStats()).count;
    if (!mounted) return;
    final ok = await _confirmer(
        context,
        'Pour choisir un nouveau code, il faut vous reconnecter par SMS (avec internet). '
        'Vos données seront effacées de l\'appareil${enAttente > 0 ? ', dont $enAttente changement(s) pas encore envoyé(s)' : ''} ; '
        'elles restent sur le serveur. Le poste garde sa lettre ; vous choisirez un nouveau code avec « Verrouiller ».');
    if (!ok) return;
    await deconnecter(db, effacerPin: true);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => widget.sortie), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
            Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('Poste ${widget.poste['code']}', style: texte.headlineSmall, textAlign: TextAlign.center),
            Text('${widget.poste['nom']}', style: texte.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextField(
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: texte.headlineSmall?.copyWith(letterSpacing: 8),
              decoration: InputDecoration(labelText: 'Code PIN', errorText: _erreur, border: const OutlineInputBorder()),
              onSubmitted: (_) => _valider(),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _valider, child: const Text('Ouvrir')),
            const SizedBox(height: 8),
            TextButton(onPressed: _oublie, child: const Text('Code PIN oublié')),
          ]),
        ),
      ),
    );
  }
}

// Liste des postes ------------------------------------------------------------

String _depuis(Object? iso) {
  final d = DateTime.tryParse('$iso');
  if (d == null) return 'jamais synchronisé';
  final e = DateTime.now().difference(d.toLocal());
  if (e.inMinutes < 60) return 'synchronisé il y a ${e.inMinutes} min';
  if (e.inHours < 24) return 'synchronisé il y a ${e.inHours} h';
  return 'synchronisé il y a ${e.inDays} j';
}

class PostesScreen extends StatelessWidget {
  const PostesScreen({super.key, required this.espace});

  final Espace espace;

  bool _gere(Map<String, Object?> p) =>
      p['site_id'] == null ? espace.fondateur : espace.gereSite(p['site_id'] as String);

  Future<void> _basculer(BuildContext context, Map<String, Object?> p) async {
    final bloquer = p['statut'] != 'bloque';
    if (await _confirmer(
        context,
        bloquer
            ? 'Bloquer le poste ${p['code']} (${p['nom']}) ? Il effacera ses données à sa prochaine connexion.'
            : 'Débloquer le poste ${p['code']} ?')) {
      await _modifier('postes', p['id'] as String, {'statut': bloquer ? 'bloque' : 'actif'});
    }
  }

  Future<void> _valider(BuildContext context, Map<String, Object?> p) async {
    if (await _confirmer(context,
        'Valider le poste ${p['code']} (${p['nom']}), activé par ${p['par'] ?? 'un membre du personnel'} ? '
        'Il pourra inscrire et encaisser.')) {
      await _modifier('postes', p['id'] as String, {'statut': 'actif'});
    }
  }

  /// Le nom se change ; la lettre, jamais (elle est dans les matricules et les reçus).
  Future<void> _renommer(BuildContext context, Map<String, Object?> p) async {
    final nom = TextEditingController(text: '${p['nom']}');
    final ok = await _formulaire(context, 'Renommer le poste ${p['code']}', (_) => [
          TextField(controller: nom, autofocus: true, decoration: _champ('Nom du poste', aide: 'Par exemple : PC du secrétariat')),
          Text('La lettre ${p['code']} ne change pas : elle figure dans les matricules et les numéros de reçu.',
              style: const TextStyle(fontSize: 13)),
        ]);
    final n = nom.text.trim();
    if (!ok || n.length < 2 || n == p['nom']) return;
    await _modifier('postes', p['id'] as String, {'nom': n});
    if (p['celui_ci'] == 1) await db.execute('UPDATE ce_poste SET nom = ?', [n]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Requete(
            '''SELECT p.*, s.nom AS site, pe.nom_complet AS par,
                 p.id = (SELECT poste_id FROM ce_poste) AS celui_ci
               FROM postes p
               LEFT JOIN sites s ON s.id = p.site_id
               LEFT JOIN personnel pe ON pe.user_id = p.user_id AND pe.organisation_id = p.organisation_id
               WHERE p.organisation_id = ?
               ORDER BY p.statut <> 'a_valider', p.numero''',
            parametres: [espace.orgId], builder: (context, postes) {
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          final largeur = MediaQuery.sizeOf(context).width;
          final telephone = largeur < 640;
          final bloques = postes.where((p) => p['statut'] == 'bloque').length;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1600),
              child: ListView(padding: EdgeInsets.all(telephone ? 12 : 16), children: [
                EnTetePage(
                  titre: 'Postes',
                  sousTitre: '${postes.length} poste(s)${bloques > 0 ? ' · $bloques bloqué(s)' : ''}'
                      '${postes.any((p) => p['statut'] == 'a_valider') ? ' · ${postes.where((p) => p['statut'] == 'a_valider').length} à valider' : ''}',
                ),
                const SizedBox(height: 8),
                Text('Un poste activé par la direction est actif tout de suite ; activé par quelqu\'un d\'autre, il attend votre '
                    'validation. Un poste perdu ou volé ? Bloquez-le : à sa prochaine connexion, il efface ses données. '
                    'Sa lettre ne sera jamais réutilisée.', style: TextStyle(fontSize: 12, color: gris)),
                const SizedBox(height: 12),
                // Les postes en attente, bien visibles en haut : la direction les valide d'un clic.
                for (final p in postes.where((p) => p['statut'] == 'a_valider' && _gere(p)))
                  Card(
                    color: Couleurs.attenteFond,
                    child: ListTile(
                      leading: const Icon(Icons.hourglass_top, color: Couleurs.attente),
                      title: Text('Poste ${p['code']} (${p['nom']}) à valider'),
                      subtitle: Text('Activé par ${p['par'] ?? 'un membre du personnel'}'
                          '${p['site'] != null ? ' · ${p['site']}' : ''}. En attendant, il peut consulter mais pas inscrire ni encaisser.'),
                      trailing: FilledButton(onPressed: () => _valider(context, p), child: const Text('Valider')),
                    ),
                  ),
                if (postes.any((p) => p['statut'] == 'a_valider' && _gere(p))) const SizedBox(height: 12),
                Tableau(
                  vide: 'Aucun poste activé pour le moment.',
                  colonnes: [
                    const ColonneTableau('', largeur: 52),
                    const ColonneTableau('Poste', flex: 3),
                    if (!telephone) const ColonneTableau('Site', flex: 2),
                    if (largeur >= 1024) const ColonneTableau('Activé par', flex: 2),
                    if (!telephone) const ColonneTableau('Dernier contact', largeur: 170),
                    const ColonneTableau('Statut', largeur: 104),
                    const ColonneTableau('', largeur: 136, droite: true),
                  ],
                  lignes: [
                    for (final p in postes)
                      [
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: Couleurs.doux(context), borderRadius: BorderRadius.circular(6)),
                          child: Text('${p['code']}', style: styleMono.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${p['nom']}${p['celui_ci'] == 1 ? ' (ce poste)' : ''}',
                              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                          Text([p['plateforme'], if (p['version_app'] != null) 'v${p['version_app']}'].whereType<String>().join(' · '),
                              style: TextStyle(fontSize: 12, color: gris)),
                        ]),
                        if (!telephone) Text('${p['site'] ?? 'Tout le groupe'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                        if (largeur >= 1024) Text('${p['par'] ?? '—'}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                        if (!telephone) Text(_depuis(p['derniere_synchro']), style: TextStyle(fontSize: 14, color: gris)),
                        switch (p['statut']) {
                          'bloque' => const Etat('Bloqué', ton: Ton.retard),
                          'a_valider' => const Etat('À valider', ton: Ton.attente),
                          _ => const Etat('Actif', ton: Ton.regle),
                        },
                        _gere(p)
                            ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                if (p['statut'] == 'a_valider')
                                  FilledButton.tonal(onPressed: () => _valider(context, p), child: const Text('Valider')),
                                PopupMenuButton<String>(
                                  tooltip: 'Actions',
                                  icon: const Icon(Icons.more_horiz, size: 18),
                                  onSelected: (a) => a == 'renommer' ? _renommer(context, p) : _basculer(context, p),
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(value: 'renommer', child: Text('Renommer')),
                                    PopupMenuItem(
                                      value: 'bloquer',
                                      child: Text(p['statut'] == 'bloque' ? 'Débloquer' : 'Bloquer',
                                          style: TextStyle(color: p['statut'] == 'bloque' ? null : Couleurs.retard)),
                                    ),
                                  ],
                                ),
                              ])
                            : const SizedBox(),
                      ],
                  ],
                ),
              ]),
            ),
          );
        }),
      );
}
