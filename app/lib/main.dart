import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase, SyncStatus;

import 'cloud.dart';
import 'schema.dart';

late final PowerSyncDatabase db;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  db = PowerSyncDatabase(schema: schema, path: p.join(dir.path, 'scolagrid.db'));
  await db.initialize();
  if (cloudConfigured) {
    await initCloud();
    unawaited(connectCloud(db));
  }
  runApp(const ScolagridApp());
}

class ScolagridApp extends StatelessWidget {
  const ScolagridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scolagrid',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF534AB7)),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF534AB7),
        brightness: Brightness.dark,
      ),
      home: const HelloScreen(),
    );
  }
}

class HelloScreen extends StatefulWidget {
  const HelloScreen({super.key});

  @override
  State<HelloScreen> createState() => _HelloScreenState();
}

class _HelloScreenState extends State<HelloScreen> {
  final _subs = <StreamSubscription<Object?>>[];
  List<Map<String, Object?>> _hellos = [];
  SyncStatus _status = db.currentStatus;
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    _subs.add(db.watch('SELECT * FROM hellos ORDER BY created_at DESC').listen((rows) {
      setState(() => _hellos = rows.toList());
      _refreshPending();
    }));
    _subs.add(db.statusStream.listen((s) {
      setState(() => _status = s);
      _refreshPending();
    }));
  }

  Future<void> _refreshPending() async {
    final stats = await db.getUploadQueueStats();
    if (mounted) setState(() => _pending = stats.count);
  }

  Future<void> _sayHello() async {
    await db.execute(
      'INSERT INTO hellos(id, message, device, created_at) VALUES(uuid(), ?, ?, ?)',
      ['Bonjour', Platform.localHostname, DateTime.now().toUtc().toIso8601String()],
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cloud = !cloudConfigured
        ? ('Non configuré', Icons.cloud_off_outlined, Colors.grey)
        : _status.connected
            ? ('Connecté', Icons.cloud_done_outlined, Colors.teal)
            : ('Hors ligne', Icons.cloud_off_outlined, Colors.orange);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Bonjour Scolagrid', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              Card(
                child: Column(children: [
                  const ListTile(
                    leading: Icon(Icons.storage_outlined, color: Colors.teal),
                    title: Text('Base locale'),
                    trailing: Text('OK'),
                  ),
                  ListTile(
                    leading: Icon(cloud.$2, color: cloud.$3),
                    title: const Text('Cloud'),
                    trailing: Text(cloud.$1),
                  ),
                  ListTile(
                    leading: const Icon(Icons.outbox_outlined),
                    title: const Text("En attente d'envoi"),
                    trailing: Text('$_pending'),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _sayHello,
                icon: const Icon(Icons.waving_hand_outlined),
                label: const Text('Dire bonjour'),
              ),
              const SizedBox(height: 16),
              for (final h in _hellos)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text('${h['message']} depuis ${h['device']}'),
                  subtitle: Text('${h['created_at']}'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
