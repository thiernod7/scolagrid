import 'dart:async';

import 'package:flutter/material.dart';

import 'accueil.dart';
import 'base.dart';
import 'cloud.dart';
import 'onboarding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ouvrirBase();
  if (cloudConfigured) {
    await initCloud();
    // Session gardée sur le poste : on reprend la synchro, même hors ligne.
    unawaited(demarrerSynchro(db));
  }
  runApp(const ScolagridApp());
}

class ScolagridApp extends StatelessWidget {
  const ScolagridApp({super.key});

  @override
  Widget build(BuildContext context) {
    const violet = Color(0xFF534AB7);
    return MaterialApp(
      title: 'Scolagrid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: violet),
      darkTheme: ThemeData(colorSchemeSeed: violet, brightness: Brightness.dark),
      // Bandeau visible sur les versions branchées sur l'environnement d'essai.
      builder: (context, child) => environnement == 'essai'
          ? Banner(message: 'ESSAI', location: BannerLocation.topEnd, child: child!)
          : child!,
      home: !cloudConfigured
          ? const _SansServeur()
          : estConnecte
              ? const AccueilScreen()
              : const BienvenueScreen(),
    );
  }
}

class _SansServeur extends StatelessWidget {
  const _SansServeur();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text("Cette version n'est reliée à aucun serveur.\n"
              "Elle a été compilée sans l'adresse du serveur Scolagrid.",
              textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
