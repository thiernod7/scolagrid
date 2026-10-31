import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException, PostgrestException;

import 'accueil.dart';
import 'base.dart';
import 'cloud.dart';

/// Mise en page commune des écrans d'onboarding : étroite et centrée,
/// lisible sur téléphone comme sur un PC de direction.
class _Page extends StatelessWidget {
  const _Page({required this.titre, this.sousTitre, required this.enfants});

  final String titre;
  final String? sousTitre;
  final List<Widget> enfants;

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              Text(titre, style: texte.headlineSmall),
              if (sousTitre != null) ...[
                const SizedBox(height: 8),
                Text(sousTitre!, style: texte.bodyMedium),
              ],
              const SizedBox(height: 24),
              ...enfants,
            ],
          ),
        ),
      ),
    );
  }
}

String _messageErreur(Object e) => switch (e) {
      AuthException(:final message) => message,
      PostgrestException(:final message) => message,
      _ => 'Impossible de joindre le serveur. Vérifiez la connexion et réessayez.',
    };

class BienvenueScreen extends StatelessWidget {
  const BienvenueScreen({super.key, this.avertissement});

  /// Message affiché en haut (par exemple : poste bloqué par l'école).
  final String? avertissement;

  @override
  Widget build(BuildContext context) {
    final texte = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              if (avertissement != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(leading: const Icon(Icons.block), title: Text(avertissement!)),
                ),
              Icon(Icons.school_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Scolagrid', style: texte.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('La gestion de votre école, même sans internet.',
                  style: texte.bodyLarge, textAlign: TextAlign.center),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const TelephoneScreen(nouvelEspace: true))),
                icon: const Icon(Icons.add_business_outlined),
                label: const Text("Créer l'espace de mon école"),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const TelephoneScreen(nouvelEspace: false))),
                icon: const Icon(Icons.login),
                label: const Text('Me connecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TelephoneScreen extends StatefulWidget {
  const TelephoneScreen({super.key, required this.nouvelEspace});

  final bool nouvelEspace;

  @override
  State<TelephoneScreen> createState() => _TelephoneScreenState();
}

class _TelephoneScreenState extends State<TelephoneScreen> {
  final _numero = TextEditingController();
  bool _envoi = false;
  String? _erreur;

  Future<void> _envoyer() async {
    final telephone = numeroInternational(_numero.text);
    if (telephone.length < 11) {
      setState(() => _erreur = 'Numéro incomplet.');
      return;
    }
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    try {
      await envoyerCode(telephone);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CodeScreen(telephone: telephone, nouvelEspace: widget.nouvelEspace)));
    } catch (e) {
      setState(() => _erreur = _messageErreur(e));
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Page(
      titre: 'Votre numéro de téléphone',
      sousTitre: 'Vous allez recevoir un code par SMS. Il faut être connecté à internet pour cette étape.',
      enfants: [
        TextField(
          controller: _numero,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Téléphone',
            hintText: '620 00 00 00',
            prefixText: '+224 ',
            errorText: _erreur,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _envoyer(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _envoi ? null : _envoyer,
          child: Text(_envoi ? 'Envoi…' : 'Recevoir le code'),
        ),
      ],
    );
  }
}

class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key, required this.telephone, required this.nouvelEspace});

  final String telephone;
  final bool nouvelEspace;

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  final _code = TextEditingController();
  bool _verif = false;
  String? _erreur;

  Future<void> _valider() async {
    setState(() {
      _verif = true;
      _erreur = null;
    });
    try {
      await verifierCode(widget.telephone, _code.text.trim());
      final dejaUnEspace = await aDejaUnEspace();
      if (!mounted) return;
      if (dejaUnEspace) {
        await demarrerSynchro(db);
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AccueilScreen()), (_) => false);
      } else {
        // Pas encore d'espace : soit on crée celui de son école, soit on a été invité.
        Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
                builder: (_) => widget.nouvelEspace ? const CreerEspaceScreen() : const InvitationScreen()),
            (_) => false);
      }
    } catch (e) {
      setState(() => _erreur = _messageErreur(e));
    } finally {
      if (mounted) setState(() => _verif = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Page(
      titre: 'Code reçu par SMS',
      sousTitre: 'Envoyé au ${widget.telephone}.',
      enfants: [
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          autofocus: true,
          maxLength: 6,
          decoration: InputDecoration(
            labelText: 'Code à 6 chiffres',
            errorText: _erreur,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _valider(),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _verif ? null : _valider,
          child: Text(_verif ? 'Vérification…' : 'Valider'),
        ),
      ],
    );
  }
}

class CreerEspaceScreen extends StatefulWidget {
  const CreerEspaceScreen({super.key});

  @override
  State<CreerEspaceScreen> createState() => _CreerEspaceScreenState();
}

class _CreerEspaceScreenState extends State<CreerEspaceScreen> {
  final _form = GlobalKey<FormState>();
  final _nom = TextEditingController();
  final _groupe = TextEditingController();
  final _ville = TextEditingController(text: 'Conakry');
  final _site = TextEditingController(text: 'Site principal');
  bool _envoi = false;
  String? _erreur;

  String? _requis(String? v) =>
      (v == null || v.trim().length < 2) ? 'Au moins 2 caractères' : null;

  Future<void> _creer() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    try {
      await creerEspaceEcole(
        nomComplet: _nom.text.trim(),
        nomGroupe: _groupe.text.trim(),
        ville: _ville.text.trim(),
        nomSite: _site.text.trim(),
      );
      await demarrerSynchro(db);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AccueilScreen()), (_) => false);
    } catch (e) {
      setState(() => _erreur = _messageErreur(e));
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  Widget _champ(TextEditingController c, String label, {String? aide}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextFormField(
          controller: c,
          validator: _requis,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
              labelText: label, helperText: aide, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return _Page(
      titre: "L'espace de votre école",
      sousTitre: 'Étape 1 sur 6. Vous pourrez tout modifier ensuite, même hors ligne.',
      enfants: [
        Form(
          key: _form,
          child: Column(children: [
            _champ(_nom, 'Votre nom complet'),
            _champ(_groupe, 'Nom du groupe scolaire', aide: 'Par exemple : Groupe scolaire Les Palmiers'),
            _champ(_ville, 'Ville'),
            _champ(_site, 'Nom du premier site', aide: "Vous ajouterez les autres sites ensuite"),
          ]),
        ),
        if (_erreur != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_erreur!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        FilledButton(
          onPressed: _envoi ? null : _creer,
          child: Text(_envoi ? 'Création…' : "Créer l'espace"),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const InvitationScreen())),
          child: const Text("Votre école utilise déjà Scolagrid ? J'ai un code d'invitation"),
        ),
      ],
    );
  }
}

/// Une personne invitée par son école saisit le code reçu : son compte est
/// relié à sa fiche du personnel, et ses fonctions lui donnent ses accès.
class InvitationScreen extends StatefulWidget {
  const InvitationScreen({super.key});

  @override
  State<InvitationScreen> createState() => _InvitationScreenState();
}

class _InvitationScreenState extends State<InvitationScreen> {
  final _code = TextEditingController();
  bool _envoi = false;
  String? _erreur;

  Future<void> _valider() async {
    if (_code.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length != 8) {
      setState(() => _erreur = 'Le code a 8 signes, par exemple K7PQ-4XZM.');
      return;
    }
    setState(() {
      _envoi = true;
      _erreur = null;
    });
    try {
      final org = await accepterInvitation(_code.text);
      if (!mounted) return;
      if (org == null) {
        setState(() => _erreur = 'Code inconnu, déjà utilisé ou expiré. Demandez un nouveau code à votre école.');
        return;
      }
      await demarrerSynchro(db);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AccueilScreen()), (_) => false);
    } catch (e) {
      setState(() => _erreur = _messageErreur(e));
    } finally {
      if (mounted) setState(() => _envoi = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Page(
      titre: "Code d'invitation",
      sousTitre: 'Votre école vous a donné un code de 8 signes. Il est valable 7 jours.',
      enfants: [
        TextField(
          controller: _code,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 9,
          decoration: InputDecoration(
            labelText: 'Code',
            hintText: 'K7PQ-4XZM',
            errorText: _erreur,
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _valider(),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _envoi ? null : _valider,
          child: Text(_envoi ? 'Vérification…' : 'Rejoindre mon école'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const CreerEspaceScreen())),
          child: const Text("Je n'ai pas de code : créer l'espace de mon école"),
        ),
      ],
    );
  }
}
