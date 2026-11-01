part of 'configuration.dart';

/// Années scolaires et leur cycle : en préparation → inscriptions ouvertes →
/// en cours → clôturée. Jamais de retour en arrière ni deux années en cours
/// (le serveur y veille). « Préparer l'année suivante » recopie les classes,
/// les frais, le calendrier et les échéances, décalés à la nouvelle rentrée.

const etatsAnnee = {
  'preparation': 'En préparation',
  'inscriptions': 'Inscriptions ouvertes',
  'en_cours': 'En cours',
  'cloturee': 'Clôturée',
};

Ton tonEtatAnnee(String? e) => switch (e) {
      'en_cours' => Ton.regle,
      'inscriptions' => Ton.info,
      'preparation' => Ton.attente,
      _ => Ton.neutre,
    };

/// « 2026-2027 » → « 2027-2028 ».
String libelleSuivant(String libelle) {
  final m = RegExp(r'^(\d{4})\s*[-/]\s*(\d{4})$').firstMatch(libelle.trim());
  if (m == null) return '';
  return '${int.parse(m[1]!) + 1}-${int.parse(m[2]!) + 1}';
}

/// Une date « AAAA-MM-JJ » décalée de [jours].
String decalerDate(Object? iso, int jours) {
  final d = DateTime.parse('$iso');
  final r = DateTime(d.year, d.month, d.day + jours);
  return '${r.year.toString().padLeft(4, '0')}-${r.month.toString().padLeft(2, '0')}-${r.day.toString().padLeft(2, '0')}';
}

class AnneesScreen extends StatelessWidget {
  const AnneesScreen({super.key, required this.espace});

  final Espace espace;

  Future<(DateTime, DateTime)?> _choisirDates(BuildContext context, String titre, TextEditingController libelle,
      DateTime debut, DateTime fin) async {
    Future<void> choisir(StateSetter maj, bool estDebut) async {
      final d = await showDatePicker(
          context: context, initialDate: estDebut ? debut : fin, firstDate: DateTime(2020), lastDate: DateTime(2045));
      if (d != null) maj(() => estDebut ? debut = d : fin = d);
    }

    final ok = await _formulaire(context, titre, (maj) => [
          TextField(controller: libelle, decoration: _champ('Année', aide: 'Par exemple 2027-2028')),
          OutlinedButton.icon(
              onPressed: () => choisir(maj, true), icon: const Icon(Icons.event), label: Text('Rentrée : ${_dateLisible(_date(debut))}')),
          OutlinedButton.icon(
              onPressed: () => choisir(maj, false),
              icon: const Icon(Icons.event_available),
              label: Text('Fin : ${_dateLisible(_date(fin))}')),
        ]);
    if (!ok || libelle.text.trim().length < 4 || !fin.isAfter(debut)) return null;
    return (debut, fin);
  }

  /// La toute première année : elle démarre en cours.
  Future<void> _premiere(BuildContext context) async {
    final libelle = TextEditingController(text: anneeScolairePour(DateTime.now()));
    final depart = int.parse(libelle.text.substring(0, 4));
    final dates = await _choisirDates(context, 'Année scolaire', libelle, DateTime(depart, 10, 1), DateTime(depart + 1, 7, 15));
    if (dates == null) return;
    await _inserer('annees_scolaires', {
      'organisation_id': espace.orgId,
      'libelle': libelle.text.trim(),
      'debut': _date(dates.$1),
      'fin': _date(dates.$2),
      'en_cours': 1,
      'etat': 'en_cours',
    });
  }

  /// Nouvelle année à partir d'une autre : classes ouvertes, frais (grille,
  /// options, examens), échéances et calendrier, décalés à la nouvelle rentrée.
  Future<void> _preparerSuivante(BuildContext context, Map<String, Object?> source) async {
    final ancienDebut = DateTime.parse('${source['debut']}');
    final ancienneFin = DateTime.parse('${source['fin']}');
    final libelle = TextEditingController(text: libelleSuivant('${source['libelle']}'));
    final dates = await _choisirDates(context, "Préparer l'année suivante", libelle,
        DateTime(ancienDebut.year + 1, ancienDebut.month, ancienDebut.day), DateTime(ancienneFin.year + 1, ancienneFin.month, ancienneFin.day));
    if (dates == null || !context.mounted) return;
    final decalage = DateTime(dates.$1.year, dates.$1.month, dates.$1.day).difference(ancienDebut).inDays;
    final m = _maintenant();
    var nbClasses = 0;
    var nbFrais = 0;
    await db.writeTransaction((tx) async {
      final id = (await tx.get('SELECT uuid() AS id'))['id'];
      await tx.execute(
          'INSERT INTO annees_scolaires (id, organisation_id, libelle, debut, fin, en_cours, etat, periodicite, nb_mois, created_at, updated_at) '
          "VALUES (?, ?, ?, ?, ?, 0, 'preparation', ?, ?, ?, ?)",
          [id, espace.orgId, libelle.text.trim(), _date(dates.$1), _date(dates.$2), source['periodicite'], source['nb_mois'], m, m]);
      for (final t in await tx.getAll('SELECT * FROM tranches_annee WHERE annee_id = ? ORDER BY ordre', [source['id']])) {
        await tx.execute(
            'INSERT INTO tranches_annee (id, organisation_id, annee_id, ordre, libelle, date_limite, part, mois, created_at, updated_at) '
            'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [espace.orgId, id, t['ordre'], t['libelle'], decalerDate(t['date_limite'], decalage), t['part'], t['mois'], m, m]);
      }
      for (final c in await tx.getAll('SELECT * FROM classes WHERE annee_id = ? AND coalesce(fermee, 0) = 0', [source['id']])) {
        await tx.execute(
            'INSERT INTO classes (id, organisation_id, site_id, annee_id, niveau_id, nom, salle, capacite, serie, lettre, '
            'professeur_principal_id, fermee, created_at, updated_at) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
            [espace.orgId, c['site_id'], id, c['niveau_id'], c['nom'], c['salle'], c['capacite'], c['serie'], c['lettre'],
              c['professeur_principal_id'], m, m]);
        nbClasses++;
      }
      for (final f in await tx.getAll('SELECT * FROM frais WHERE annee_id = ?', [source['id']])) {
        final fid = (await tx.get('SELECT uuid() AS id'))['id'];
        await tx.execute(
            'INSERT INTO frais (id, organisation_id, annee_id, site_id, niveau_id, libelle, montant_gnf, periodicite, type_frais, examen, '
            'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [fid, espace.orgId, id, f['site_id'], f['niveau_id'], f['libelle'], f['montant_gnf'], f['periodicite'], f['type_frais'],
              f['examen'] ?? 0, m, m]);
        for (final e in await tx.getAll('SELECT * FROM echeances WHERE frais_id = ? ORDER BY ordre', [f['id']])) {
          await tx.execute(
              'INSERT INTO echeances (id, organisation_id, frais_id, ordre, libelle, montant_gnf, date_limite, created_at, updated_at) '
              'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?)',
              [espace.orgId, fid, e['ordre'], e['libelle'], e['montant_gnf'], decalerDate(e['date_limite'], decalage), m, m]);
        }
        nbFrais++;
      }
    });
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${libelle.text.trim()} préparée : $nbClasses classe(s) et $nbFrais frais recopiés. '
            'Ajustez-les, puis ouvrez les inscriptions.')));
  }

  Future<void> _ouvrirInscriptions(BuildContext context, Map<String, Object?> a) async {
    if (!await _confirmer(context,
        'Ouvrir les inscriptions pour ${a['libelle']} ? Les réinscriptions et nouvelles inscriptions pourront se faire '
        "dès maintenant, pendant que l'année en cours continue.")) {
      return;
    }
    await _modifier('annees_scolaires', a['id'] as String, {'etat': 'inscriptions'});
  }

  /// Démarrer une année : celle en cours est clôturée dans le même geste.
  Future<void> _demarrer(BuildContext context, Map<String, Object?> a, Map<String, Object?>? enCours) async {
    final question = enCours == null
        ? 'Démarrer ${a['libelle']} ?'
        : 'Clôturer ${enCours['libelle']} et démarrer ${a['libelle']} ?\n\n'
            '${enCours['libelle']} passera en lecture seule ; ses arriérés resteront encaissables. On ne revient pas en arrière.';
    if (!await _confirmer(context, question)) return;
    final m = _maintenant();
    await db.writeTransaction((tx) async {
      // D'abord clôturer l'ancienne : jamais deux années en cours.
      if (enCours != null) {
        await tx.execute("UPDATE annees_scolaires SET etat = 'cloturee', en_cours = 0, cloturee_le = ?, updated_at = ? WHERE id = ?",
            [m, m, enCours['id']]);
      }
      await tx.execute("UPDATE annees_scolaires SET etat = 'en_cours', en_cours = 1, updated_at = ? WHERE id = ?", [m, a['id']]);
    });
  }

  Future<void> _cloturer(BuildContext context, Map<String, Object?> a) async {
    if (!await _confirmer(context,
        'Clôturer ${a['libelle']} sans démarrer de nouvelle année ?\n\nElle passera en lecture seule ; '
        'ses arriérés resteront encaissables. On ne revient pas en arrière.')) {
      return;
    }
    final m = _maintenant();
    await db.execute("UPDATE annees_scolaires SET etat = 'cloturee', en_cours = 0, cloturee_le = ?, updated_at = ? WHERE id = ?",
        [m, m, a['id']]);
  }

  @override
  Widget build(BuildContext context) {
    final f = espace.fondateur;
    return _Page(
      titre: 'Années scolaires',
      corps: Requete('''
          SELECT a.*,
            (SELECT count(*) FROM classes c WHERE c.annee_id = a.id AND coalesce(c.fermee, 0) = 0) AS nb_classes,
            (SELECT count(*) FROM frais fr WHERE fr.annee_id = a.id) AS nb_frais,
            (SELECT count(*) FROM inscriptions i WHERE i.annee_id = a.id AND i.statut IN ('en_attente', 'actif', 'suspendu')) AS inscrits
          FROM annees_scolaires a WHERE a.organisation_id = ? ORDER BY a.debut DESC''', parametres: [espace.orgId],
          builder: (context, annees) {
        final gris = Theme.of(context).colorScheme.onSurfaceVariant;
        if (annees.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Aucune année scolaire.'),
              const SizedBox(height: 12),
              if (f) FilledButton(onPressed: () => _premiere(context), child: const Text('Créer celle de cette rentrée')),
            ]),
          );
        }
        final enCours = annees.where((a) => a['etat'] == 'en_cours' || (a['etat'] == null && a['en_cours'] == 1)).firstOrNull;
        final plusRecente = annees.first;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
          Text("Une année passe par quatre étapes : en préparation, inscriptions ouvertes, en cours, clôturée. "
              "On ne revient jamais en arrière. Une année clôturée ne se modifie plus, mais ses arriérés s'encaissent toujours.",
              style: TextStyle(fontSize: 13, color: gris)),
          const SizedBox(height: 12),
          for (final a in annees)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${a['libelle']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                    Etat(etatsAnnee[a['etat']] ?? (a['en_cours'] == 1 ? 'En cours' : '—'), ton: tonEtatAnnee(a['etat'] as String?)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                      'Du ${_dateLisible(a['debut'])} au ${_dateLisible(a['fin'])} · ${a['nb_classes']} classe(s) · '
                      '${a['nb_frais']} frais · ${a['inscrits']} élève(s)'
                      '${a['etat'] == 'cloturee' && a['cloturee_le'] != null ? ' · clôturée le ${_dateLisible(a['cloturee_le'])}' : ''}',
                      style: TextStyle(fontSize: 13, color: gris)),
                  if (f && a['etat'] != 'cloturee') ...[
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      if (a['etat'] == 'preparation')
                        OutlinedButton(onPressed: () => _ouvrirInscriptions(context, a), child: const Text('Ouvrir les inscriptions')),
                      if (a['etat'] == 'preparation' || a['etat'] == 'inscriptions')
                        FilledButton(
                          onPressed: () => _demarrer(context, a, enCours),
                          child: Text(enCours == null ? "Démarrer l'année" : 'Clôturer ${enCours['libelle']} et démarrer'),
                        ),
                      if (a['etat'] == 'en_cours' && identical(a, plusRecente))
                        FilledButton.icon(
                          onPressed: () => _preparerSuivante(context, a),
                          icon: const Icon(Icons.copy_all_outlined, size: 18),
                          label: const Text("Préparer l'année suivante"),
                        ),
                      if (a['etat'] == 'en_cours' && identical(a, plusRecente))
                        TextButton(onPressed: () => _cloturer(context, a), child: const Text('Clôturer')),
                    ]),
                  ],
                ]),
              ),
            ),
        ]);
      }),
    );
  }
}
