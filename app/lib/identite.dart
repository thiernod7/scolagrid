part of 'configuration.dart';

/// Identité de l'école : ce qui figure sur les documents (attestations, reçus)
/// et les codes qui entrent dans les numéros (matricules, reçus).

class IdentiteEcoleScreen extends StatelessWidget {
  const IdentiteEcoleScreen({super.key, required this.espace});

  final Espace espace;

  Future<void> _choisirSigle(BuildContext context, Map<String, Object?> org) async {
    final code = TextEditingController(text: codeSuggere('${org['nom']}'));
    final ok = await _formulaire(context, "Sigle de l'école", (_) => [
          const Text('Le sigle entre dans les matricules et les numéros de reçu, '
              'par exemple ALPHA-DONKA-2026-B042. Il ne pourra plus être modifié.'),
          TextField(
            controller: code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 10,
            decoration: _champ('Sigle', aide: '2 à 10 lettres ou chiffres, sans espace'),
          ),
        ]);
    final c = code.text.trim().toUpperCase();
    if (!ok || !context.mounted) return;
    final messager = ScaffoldMessenger.of(context);
    if (!codeValide(c)) {
      messager.showSnackBar(const SnackBar(content: Text('Le sigle doit avoir 2 à 10 lettres ou chiffres.')));
      return;
    }
    try {
      await definirSigle(org['id'] as String, c);
      messager.showSnackBar(SnackBar(content: Text('Sigle $c enregistré.')));
    } on PostgrestException catch (e) {
      messager.showSnackBar(SnackBar(
          content: Text(e.code == '23505' ? 'Le sigle $c est déjà pris par une autre école.' : e.message)));
    } catch (_) {
      messager.showSnackBar(const SnackBar(content: Text('Il faut internet pour enregistrer le sigle.')));
    }
  }

  Future<void> _modifierIdentite(BuildContext context, Map<String, Object?> org) async {
    TextEditingController c(String col) => TextEditingController(text: org[col] as String? ?? '');
    final champs = {
      'nom_officiel': (c('nom_officiel')..text = (org['nom_officiel'] ?? org['nom']) as String, 'Nom officiel', null),
      'slogan': (c('slogan'), 'Devise (facultatif)', 'Excellence et Discipline'),
      'quartier': (c('quartier'), 'Quartier', 'Donka'),
      'telephone': (c('telephone'), 'Téléphone', '620 00 00 00'),
      'email': (c('email'), 'E-mail (facultatif)', null),
      'responsable_nom': (c('responsable_nom'), 'Responsable légal : nom complet', null),
      'responsable_titre': (c('responsable_titre'), 'Responsable légal : titre', 'Directeur, Fondateur, Proviseur…'),
    };
    final ok = await _formulaire(context, "Identité de l'école", (_) => [
          for (final e in champs.entries)
            TextField(
              controller: e.value.$1,
              keyboardType: e.key == 'telephone' ? TextInputType.phone : null,
              decoration: _champ(e.value.$2, aide: e.value.$3),
            ),
        ]);
    if (!ok) return;
    String? val(String col) => champs[col]!.$1.text.trim().isEmpty ? null : champs[col]!.$1.text.trim();
    final tel = val('telephone');
    final email = val('email');
    if (!context.mounted) return;
    // Vérifié ici : le serveur refuserait la modification entière.
    if (email != null && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E-mail invalide.')));
      return;
    }
    await _modifier('organisations', org['id'] as String, {
      'nom_officiel': val('nom_officiel'),
      'slogan': val('slogan'),
      'quartier': val('quartier'),
      'telephone': tel == null ? null : numeroInternational(tel),
      'email': email,
      'responsable_nom': val('responsable_nom'),
      'responsable_titre': val('responsable_titre'),
    });
  }

  Future<void> _codeSite(BuildContext context, Map<String, Object?> site) async {
    final code = TextEditingController(text: codeSuggere('${site['nom']}'));
    final ok = await _formulaire(context, 'Code du site ${site['nom']}', (_) => [
          const Text('Le code du site entre dans les matricules et les numéros de reçu. '
              'Il ne pourra plus être modifié.'),
          TextField(
            controller: code,
            textCapitalization: TextCapitalization.characters,
            maxLength: 10,
            decoration: _champ('Code', aide: 'Par exemple DONKA, ou S01'),
          ),
        ]);
    final c = code.text.trim().toUpperCase();
    if (!ok || !context.mounted) return;
    final pris = await db.getOptional('SELECT 1 FROM sites WHERE organisation_id = ? AND code = ?', [espace.orgId, c]);
    if (!context.mounted) return;
    if (!codeValide(c) || pris != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(pris != null ? 'Ce code est déjà utilisé par un autre site.' : 'Le code doit avoir 2 à 10 lettres ou chiffres.')));
      return;
    }
    await _modifier('sites', site['id'] as String, {'code': c});
  }

  @override
  Widget build(BuildContext context) => _Page(
        titre: "Identité de l'école",
        corps: Requete('SELECT * FROM organisations WHERE id = ?', parametres: [espace.orgId], builder: (context, l) {
          if (l.isEmpty) return _vide('Organisation introuvable.');
          final org = l.first;
          final texte = Theme.of(context).textTheme;
          return Requete('SELECT * FROM sites WHERE organisation_id = ? ORDER BY created_at',
              parametres: [espace.orgId], builder: (context, sites) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.tag),
                  title: Text(org['code'] == null ? 'Sigle à choisir' : 'Sigle : ${org['code']}'),
                  subtitle: const Text('Dans les matricules et les reçus. Définitif.'),
                  trailing: org['code'] == null && espace.fondateur
                      ? FilledButton(onPressed: () => _choisirSigle(context, org), child: const Text('Choisir'))
                      : null,
                ),
              ),
              for (final s in sites)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.location_city_outlined),
                    title: Text('${s['nom']}'),
                    subtitle: Text(s['code'] == null ? 'Code du site à choisir' : 'Code : ${s['code']}'),
                    trailing: s['code'] == null && espace.gereSite(s['id'] as String)
                        ? FilledButton(onPressed: () => _codeSite(context, s), child: const Text('Choisir'))
                        : null,
                  ),
                ),
              const SizedBox(height: 12),
              Text('Sur les documents', style: texte.titleMedium),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text('${org['nom_officiel'] ?? org['nom']}'),
                  subtitle: Text([
                    if (org['slogan'] != null) '« ${org['slogan']} »',
                    [org['quartier'], org['ville']].where((x) => x != null).join(', '),
                    if (org['telephone'] != null) 'Tél. ${org['telephone']}',
                    if (org['email'] != null) org['email'],
                    org['responsable_nom'] == null
                        ? 'Responsable légal à renseigner'
                        : '${org['responsable_nom']}, ${org['responsable_titre'] ?? ''}',
                  ].join('\n')),
                  isThreeLine: true,
                  trailing: espace.fondateur ? const Icon(Icons.edit_outlined) : null,
                  onTap: espace.fondateur ? () => _modifierIdentite(context, org) : null,
                ),
              ),
            ]);
          });
        }),
      );
}
