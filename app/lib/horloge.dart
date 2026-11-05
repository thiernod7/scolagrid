part of 'configuration.dart';

/// Horloge de l'ordinateur. L'app date les paiements, dépenses et remboursements
/// avec elle : un ordinateur qui n'est pas à la bonne date range l'argent dans
/// la mauvaise journée de caisse. On la compare à celle du serveur ; hors ligne,
/// elle ne peut pas être antérieure à la dernière heure donnée par le serveur.

/// null : à l'heure (ou pas vérifiable). Sinon, ce que dit l'ordinateur et la vraie date.
final horlogeFausse = ValueNotifier<({DateTime poste, DateTime vraie})?>(null);

const _toleranceHorloge = Duration(minutes: 10);

Future<void> verifierHorloge() async {
  final avant = DateTime.now();
  final serveur = await heureServeur();
  final poste = DateTime.now();
  if (serveur != null) {
    // L'appel a pris un peu de temps : on compare au milieu de l'aller-retour.
    final milieu = avant.add(poste.difference(avant) ~/ 2);
    horlogeFausse.value = milieu.difference(serveur).abs() > _toleranceHorloge ? (poste: poste, vraie: serveur) : null;
    try {
      await db.writeTransaction((tx) async {
        await tx.execute("DELETE FROM preferences WHERE id = 'heure_serveur'");
        await tx.execute("INSERT INTO preferences (id, valeur) VALUES ('heure_serveur', ?)", [serveur.toUtc().toIso8601String()]);
      });
    } catch (_) {}
    return;
  }
  // Hors ligne : l'ordinateur a-t-il reculé avant la dernière heure connue du serveur ?
  try {
    final p = await db.getOptional("SELECT valeur FROM preferences WHERE id = 'heure_serveur'");
    final vu = DateTime.tryParse('${p?['valeur'] ?? ''}')?.toLocal();
    horlogeFausse.value = vu != null && poste.isBefore(vu.subtract(const Duration(hours: 1))) ? (poste: poste, vraie: vu) : null;
  } catch (_) {}
}

String _dateHeure(DateTime d) =>
    '${_dateLisible(_date(d))} à ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String messageHorloge(({DateTime poste, DateTime vraie}) h) =>
    "Cet ordinateur indique le ${_dateHeure(h.poste)}, alors qu'on est le ${_dateLisible(_date(h.vraie))}"
    '. '
    "Corrigez la date et l'heure de l'appareil (Windows : Paramètres › Heure et langue › « Régler l'heure automatiquement »).";

/// Encaisser, sortir de l'argent, rembourser : pas tant que la date de l'appareil est fausse.
Future<bool> horlogeBloque(BuildContext context) async {
  if (horlogeFausse.value != null) await verifierHorloge();
  final h = horlogeFausse.value;
  if (h == null || !context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.schedule, color: Couleurs.retard),
      title: const Text("La date de l'appareil est fausse"),
      content: Text('${messageHorloge(h)}\n\nTant qu\'elle n\'est pas corrigée, l\'argent serait rangé dans la mauvaise journée de caisse.'),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Compris'))],
    ),
  );
  return true;
}

/// Bandeau rouge en haut de l'app tant que la date de l'appareil est fausse.
class BandeauHorloge extends StatelessWidget {
  const BandeauHorloge({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: horlogeFausse,
        builder: (context, h, _) {
          if (h == null) return const SizedBox.shrink();
          return Material(
            color: Couleurs.retard,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Icons.schedule, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(messageHorloge(h), style: const TextStyle(color: Colors.white, fontSize: 13))),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: verifierHorloge,
                  child: const Text('Vérifier à nouveau'),
                ),
              ]),
            ),
          );
        },
      );
}
