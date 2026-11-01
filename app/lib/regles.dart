part of 'configuration.dart';

/// Pièces du dossier et règles générales de l'école.

const _admissions = {'nouvelle': 'Nouvelle', 'reinscription': 'Réinscription', 'transfert': 'Transfert'};

/// « Carnet de santé » → carnet_de_sante (code d'une pièce, unique dans l'école).
String _codePiece(String libelle, Iterable<String> pris) {
  const de = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿ';
  const vers = 'aaaaaaceeeeiiiinooooouuuuyy';
  final b = StringBuffer();
  for (final c in libelle.toLowerCase().split('')) {
    final i = de.indexOf(c);
    b.write(i >= 0 ? vers[i] : (RegExp('[a-z]').hasMatch(c) ? c : '_'));
  }
  var base = b.toString().replaceAll(RegExp('_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  if (base.length < 2) base = 'piece';
  if (base.length > 26) base = base.substring(0, 26);
  var code = base;
  var n = 2;
  while (pris.contains(code)) {
    code = '${base}_${String.fromCharCode(96 + n++)}';
  }
  return code;
}

class PiecesDossierScreen extends StatelessWidget {
  const PiecesDossierScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _adopterStandard() async {
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      for (var i = 0; i < piecesStandard.length; i++) {
        final p = piecesStandard[i];
        await tx.execute(
            'INSERT INTO pieces_dossier (id, organisation_id, code, libelle, admissions, cycles, obligatoire, ordre, actif, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)',
            [espace.orgId, p.code, p.libelle, p.admissions?.join(','), p.cycles?.join(','), p.obligatoire ? 1 : 0, i + 1, m, m]);
      }
    });
  }

  Future<void> _editer(BuildContext context, {Map<String, Object?>? piece, required List<Map<String, Object?>> toutes}) async {
    final libelle = TextEditingController(text: '${piece?['libelle'] ?? ''}');
    var obligatoire = piece?['obligatoire'] == 1;
    final admissions = '${piece?['admissions'] ?? ''}'.split(',').where((x) => x.isNotEmpty).toSet();
    final cyclesChoisis = '${piece?['cycles'] ?? ''}'.split(',').where((x) => x.isNotEmpty).toSet();
    final ok = await _formulaire(context, piece == null ? 'Nouvelle pièce' : 'Modifier la pièce', (maj) => [
          TextField(controller: libelle, autofocus: piece == null, decoration: _champ('Libellé', aide: 'Fiche de transfert, Carnet de santé…')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: obligatoire,
            onChanged: (v) => maj(() => obligatoire = v),
            title: const Text('Obligatoire'),
            subtitle: const Text("Signalée si elle manque, sans bloquer l'inscription."),
          ),
          const Text("Demandée pour (aucune case : pour toutes)", style: TextStyle(fontSize: 13)),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in _admissions.entries)
              FilterChip(
                label: Text(a.value),
                selected: admissions.contains(a.key),
                onSelected: (v) => maj(() => v ? admissions.add(a.key) : admissions.remove(a.key)),
              ),
          ]),
          const Text('Cycles (aucune case : tous)', style: TextStyle(fontSize: 13)),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in cycles.entries)
              FilterChip(
                label: Text(c.value),
                selected: cyclesChoisis.contains(c.key),
                onSelected: (v) => maj(() => v ? cyclesChoisis.add(c.key) : cyclesChoisis.remove(c.key)),
              ),
          ]),
        ]);
    if (!ok || libelle.text.trim().length < 2) return;
    final valeurs = <String, Object?>{
      'libelle': libelle.text.trim(),
      'obligatoire': obligatoire ? 1 : 0,
      'admissions': admissions.isEmpty || admissions.length == _admissions.length
          ? null
          : _admissions.keys.where(admissions.contains).join(','),
      'cycles': cyclesChoisis.isEmpty || cyclesChoisis.length == cycles.length ? null : cycles.keys.where(cyclesChoisis.contains).join(','),
    };
    if (piece == null) {
      await _inserer('pieces_dossier', {
        ...valeurs,
        'organisation_id': espace.orgId,
        'code': _codePiece(libelle.text.trim(), toutes.map((p) => '${p['code']}')),
        'ordre': toutes.length + 1,
        'actif': 1,
      });
    } else {
      await _modifier('pieces_dossier', piece['id'] as String, valeurs);
    }
  }

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT * FROM pieces_dossier WHERE organisation_id = ? ORDER BY ordre, libelle',
        parametres: [espace.orgId],
        builder: (context, pieces) {
          final f = espace.fondateur;
          final gris = Theme.of(context).colorScheme.onSurfaceVariant;
          String portee(Object? admissions, Object? cyclesTexte) {
            final a = '${admissions ?? ''}'.split(',').where((x) => x.isNotEmpty).map((x) => _admissions[x] ?? x).join(', ');
            final c = '${cyclesTexte ?? ''}'.split(',').where((x) => x.isNotEmpty).map((x) => cycles[x] ?? x).join(', ');
            return [a.isEmpty ? 'Toutes les admissions' : a, c.isEmpty ? 'tous les cycles' : c].join(' · ');
          }

          final actives = pieces.where((p) => p['actif'] == 1).toList();
          return _Page(
            titre: 'Pièces du dossier',
            ajouter: f && pieces.isNotEmpty ? () => _editer(context, toutes: pieces) : null,
            libelleAjouter: 'Pièce',
            corps: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
              Text("Les pièces que l'école demande aux familles. Une pièce obligatoire manquante est signalée sur la fiche "
                  "et dans « À faire », sans bloquer l'inscription.", style: TextStyle(fontSize: 13, color: gris)),
              const SizedBox(height: 12),
              if (pieces.isEmpty) ...[
                Text('Liste proposée :', style: TextStyle(fontSize: 13, color: gris)),
                for (final p in piecesStandard)
                  Card(
                    child: ListTile(
                      title: Text(p.obligatoire ? '${p.libelle} (obligatoire)' : p.libelle),
                      subtitle: Text(portee(p.admissions?.join(','), p.cycles?.join(','))),
                    ),
                  ),
                if (f) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(onPressed: _adopterStandard, child: const Text('Utiliser cette liste et la modifier')),
                  ),
                ],
              ],
              for (final p in pieces)
                Card(
                  child: ListTile(
                    title: Text('${p['libelle']}', style: TextStyle(color: p['actif'] == 1 ? null : gris)),
                    subtitle: Text([
                      portee(p['admissions'], p['cycles']),
                      if (p['actif'] != 1) 'retirée',
                    ].join(' · ')),
                    leading: p['obligatoire'] == 1 ? const Etat('Obligatoire', ton: Ton.attente) : const Etat('Facultative'),
                    trailing: f
                        ? PopupMenuButton<String>(
                            onSelected: (v) => switch (v) {
                              'modifier' => _editer(context, piece: p, toutes: pieces),
                              'retirer' => _modifier('pieces_dossier', p['id'] as String, {'actif': 0}),
                              _ => _modifier('pieces_dossier', p['id'] as String, {'actif': 1}),
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'modifier', child: Text('Modifier')),
                              if (p['actif'] == 1)
                                const PopupMenuItem(value: 'retirer', child: Text('Ne plus demander'))
                              else
                                const PopupMenuItem(value: 'remettre', child: Text('Demander à nouveau')),
                            ],
                          )
                        : null,
                  ),
                ),
              if (pieces.isNotEmpty && actives.isEmpty)
                Text('Aucune pièce demandée.', style: TextStyle(fontSize: 13, color: gris)),
            ]),
          );
        },
      );
}

class ReglesGeneralesScreen extends StatelessWidget {
  const ReglesGeneralesScreen({super.key, required this.espace});

  final Espace espace;

  static const _blocages = {
    'non': ('Ne rien faire', 'Les documents s\'impriment même avec des arriérés.'),
    'alerte': ('Prévenir', 'On rappelle les arriérés avant d\'imprimer ; on peut continuer.'),
    'bloquer': ('Bloquer', 'Pas d\'attestation ni de certificat avec des arriérés, sauf levée par la direction avec un motif.'),
  };

  @override
  Widget build(BuildContext context) => Requete(
        'SELECT blocage_documents, seuil_recouvrement FROM organisations WHERE id = ?',
        parametres: [espace.orgId],
        builder: (context, l) {
          if (l.isEmpty) return _Page(titre: 'Règles générales', corps: _vide('Organisation introuvable.'));
          final o = l.first;
          final f = espace.fondateur;
          final schema = Theme.of(context).colorScheme;
          final regle = o['blocage_documents'] as String? ?? 'alerte';
          final seuil = o['seuil_recouvrement'] as int? ?? 70;
          return _Page(
            titre: 'Règles générales',
            corps: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
              const Text('Attestations et certificats quand il y a des arriérés',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text("Le reçu n'est jamais bloqué.", style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
              const SizedBox(height: 8),
              for (final b in _blocages.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: f ? () => _modifier('organisations', espace.orgId, {'blocage_documents': b.key}) : null,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: regle == b.key ? schema.onSurface : schema.outlineVariant, width: regle == b.key ? 1.5 : 1),
                      ),
                      child: Row(children: [
                        Icon(regle == b.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(b.value.$1, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                            Text(b.value.$2, style: TextStyle(fontSize: 12, color: schema.onSurfaceVariant)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Card(
                child: ListTile(
                  title: const Text('Seuil du taux de recouvrement'),
                  subtitle: Text('Sur le tableau de bord, le taux passe au rouge sous $seuil %.'),
                  trailing: f ? const Icon(Icons.edit_outlined, size: 18) : null,
                  onTap: f
                      ? () async {
                          final c = TextEditingController(text: '$seuil');
                          final ok = await _formulaire(context, 'Seuil de recouvrement', (_) => [
                                TextField(
                                  controller: c,
                                  autofocus: true,
                                  keyboardType: TextInputType.number,
                                  decoration: _champ('Pourcentage', suffixe: '%', aide: 'De 0 à 100'),
                                ),
                              ]);
                          final n = int.tryParse(c.text.trim());
                          if (ok && n != null && n >= 0 && n <= 100) {
                            await _modifier('organisations', espace.orgId, {'seuil_recouvrement': n});
                          }
                        }
                      : null,
                ),
              ),
            ]),
          );
        },
      );
}
