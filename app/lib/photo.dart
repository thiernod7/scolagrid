part of 'configuration.dart';

/// Photos d'identité des élèves : prises au téléphone ou choisies dans un
/// fichier, réduites sur le poste (quelques dizaines de Ko), puis rangées dans
/// la base locale : elles s'affichent sans réseau, sur tous les postes.

/// La caméra existe sur téléphone (et sur le web mobile) ; sur PC, on choisit un fichier.
bool get cameraDisponible => kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// Photo prête à ranger : type et contenu en base64.
typedef PhotoPrete = ({String type, String base64});

/// Réduit une image trop lourde (cas du PC, où la photo n'est pas compressée).
Future<PhotoPrete> _reduire(Uint8List octets, String type) async {
  var donnees = octets;
  var t = type;
  for (final largeur in [360, 240, 160]) {
    if (donnees.length <= 150000) break;
    final codec = await ui.instantiateImageCodec(octets, targetWidth: largeur);
    final image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) break;
    donnees = png.buffer.asUint8List();
    t = 'image/png';
  }
  return (type: t, base64: base64Encode(donnees));
}

/// [taille] : côté maximal en pixels (un justificatif doit rester lisible).
Future<PhotoPrete?> choisirPhoto(BuildContext context, {required bool camera, double taille = 480}) async {
  final messager = ScaffoldMessenger.of(context);
  try {
    final f = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: taille,
      maxHeight: taille,
      imageQuality: taille > 480 ? 60 : 70,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (f == null) return null;
    final octets = await f.readAsBytes();
    final type = (f.mimeType ?? '').contains('png') || f.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    final p = await _reduire(octets, type);
    if (p.base64.length > 390000) {
      messager.showSnackBar(const SnackBar(content: Text('Photo trop lourde, même réduite. Essayez une autre image.')));
      return null;
    }
    return p;
  } catch (_) {
    messager.showSnackBar(const SnackBar(content: Text("Impossible d'ouvrir la photo sur cet appareil.")));
    return null;
  }
}

/// Range la photo d'un élève (la remplace s'il en avait une).
Future<void> enregistrerPhoto({required String orgId, required String eleveId, required PhotoPrete photo}) async {
  final m = _maintenant();
  await db.writeTransaction((t) async {
    final existante = await t.getOptional('SELECT id FROM photos_eleves WHERE eleve_id = ?', [eleveId]);
    if (existante != null) {
      await t.execute('UPDATE photos_eleves SET type_image = ?, image = ?, par = ?, updated_at = ? WHERE id = ?',
          [photo.type, photo.base64, monId, m, existante['id']]);
    } else {
      await t.execute(
          'INSERT INTO photos_eleves (id, organisation_id, eleve_id, type_image, image, par, created_at, updated_at) '
          'VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?)',
          [orgId, eleveId, photo.type, photo.base64, monId, m, m]);
    }
    // La pièce « Photo d'identité » se coche toute seule.
    final e = await t.getOptional('SELECT pieces_dossier FROM eleves WHERE id = ?', [eleveId]);
    final pieces = '${e?['pieces_dossier'] ?? ''}'.split(',').where((x) => x.isNotEmpty).toList();
    if (e != null && !pieces.contains('photo')) {
      await t.execute('UPDATE eleves SET pieces_dossier = ?, updated_at = ? WHERE id = ?', [[...pieces, 'photo'].join(','), m, eleveId]);
    }
  });
}

// Images déjà décodées, par élève et par version : une liste de 300 élèves ne
// relit pas chaque photo à chaque mise à jour.
final _cachePhotos = <String, (String, MemoryImage)>{};

/// Photo de l'élève dans un rond, ou ses initiales s'il n'en a pas.
/// [version] : date de mise à jour de la photo (null = pas de photo).
class PhotoEleve extends StatefulWidget {
  const PhotoEleve({super.key, required this.eleveId, required this.nom, this.version, this.taille = 40, this.carre = false});

  final String eleveId;
  final String nom;
  final String? version;
  final double taille;

  /// Grande photo carrée (grille des élèves) au lieu d'un rond.
  final bool carre;

  @override
  State<PhotoEleve> createState() => _PhotoEleveState();
}

class _PhotoEleveState extends State<PhotoEleve> {
  MemoryImage? _image;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  @override
  void didUpdateWidget(PhotoEleve ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.version != widget.version || ancien.eleveId != widget.eleveId) _charger();
  }

  Future<void> _charger() async {
    final v = widget.version;
    if (v == null) {
      if (_image != null) setState(() => _image = null);
      return;
    }
    final c = _cachePhotos[widget.eleveId];
    if (c != null && c.$1 == v) {
      setState(() => _image = c.$2);
      return;
    }
    final p = await db.getOptional('SELECT image FROM photos_eleves WHERE eleve_id = ?', [widget.eleveId]);
    if (p == null || !mounted) return;
    try {
      final img = MemoryImage(base64Decode(p['image'] as String));
      _cachePhotos[widget.eleveId] = (v, img);
      setState(() => _image = img);
    } catch (_) {
      // Photo illisible : on garde les initiales.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.carre) {
      return _image == null
          ? Container(color: Couleurs.doux(context), alignment: Alignment.center, child: Initiales(widget.nom, taille: 64))
          : Image(image: _image!, fit: BoxFit.cover, width: double.infinity, height: double.infinity);
    }
    return _image == null
        ? Initiales(widget.nom, taille: widget.taille)
        : CircleAvatar(radius: widget.taille / 2, backgroundImage: _image);
  }
}

/// Logo, signature et cachet de l'école, prêts pour les documents.
Future<ImagesEcole> _imagesEcole(Object? orgId) async {
  Uint8List? lire(Map<String, Object?>? r) {
    try {
      return r == null ? null : base64Decode(r['image'] as String);
    } catch (_) {
      return null;
    }
  }

  final l = {
    for (final r in await db.getAll('SELECT sorte, image FROM images_ecole WHERE organisation_id = ?', [orgId]))
      r['sorte'] as String: Map<String, Object?>.from(r),
  };
  return ImagesEcole(logo: lire(l['logo']), signature: lire(l['signature']), cachet: lire(l['cachet']));
}
