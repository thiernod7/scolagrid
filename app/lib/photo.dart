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

/// Photo d'identité d'un élève : prise ou choisie, puis cadrée au format 3:4.
/// Le visage est placé tout seul ; on ajuste au doigt (ou à la souris) si besoin.
/// Enregistrée en 600 × 800 : nette en plein écran comme sur la carte scolaire.
Future<PhotoPrete?> choisirPortrait(BuildContext context, {required bool camera}) async {
  final messager = ScaffoldMessenger.of(context);
  void dire(String m) => messager.showSnackBar(SnackBar(content: Text(m)));
  Uint8List octets;
  try {
    final f = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 92,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (f == null) return null;
    octets = await f.readAsBytes();
  } catch (_) {
    dire("Impossible d'ouvrir la photo sur cet appareil.");
    return null;
  }
  if (!context.mounted) return null;
  final photo = await _patienter(context, 'Préparation de la photo…', () => compute(preparerPortrait, octets));
  if (photo == null) {
    dire("Cette image n'a pas pu être lue. Essayez une photo JPEG ou PNG.");
    return null;
  }
  if (!context.mounted) return null;
  final cadre = await Navigator.of(context).push<CadrePortrait>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _RecadragePortrait(photo: photo)));
  if (cadre == null || !context.mounted) return null;
  final jpeg = await _patienter(context, 'Enregistrement de la photo…', () => compute(exporterCadre, (photo, cadre)));
  if (jpeg == null) {
    dire("La photo n'a pas pu être préparée. Réessayez.");
    return null;
  }
  return (type: 'image/jpeg', base64: base64Encode(jpeg));
}

/// Un calcul un peu long (une à quelques secondes) avec une fenêtre d'attente ; null si échec.
Future<T?> _patienter<T>(BuildContext context, String message, Future<T> Function() travail) async {
  final nav = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Expanded(child: Text(message)),
        ]),
      ),
    ),
  ));
  // Laisser la fenêtre s'afficher (sur le web, le calcul occupe l'écran).
  await Future<void>.delayed(const Duration(milliseconds: 80));
  try {
    return await travail();
  } catch (_) {
    return null;
  } finally {
    nav.pop();
  }
}

/// Le cadre 3:4 est fixe ; on déplace et agrandit la photo dessous.
/// L'ovale indique où placer le visage.
class _RecadragePortrait extends StatefulWidget {
  const _RecadragePortrait({required this.photo});

  final PhotoACadrer photo;

  @override
  State<_RecadragePortrait> createState() => _RecadragePortraitState();
}

class _RecadragePortraitState extends State<_RecadragePortrait> {
  final _transformation = TransformationController();
  double? _largeurVue;

  PhotoACadrer get _p => widget.photo;
  double get _aw => _p.largeurApercu.toDouble();
  double get _ah => _p.hauteurApercu.toDouble();

  /// Rapport entre l'aperçu et la photo entière.
  double get _f => _aw / _p.image.width;

  double _echelleMin(double vw) => math.max(vw / _aw, vw * 4 / 3 / _ah);

  void _appliquer(CadrePortrait c, double vw) {
    final s = math.max(_echelleMin(vw), vw / (c.largeur * _f));
    _placer(s, -c.x * _f * s, -c.y * _f * s, vw);
  }

  void _placer(double s, double tx, double ty, double vw) {
    final vh = vw * 4 / 3;
    tx = tx.clamp(math.min(0.0, vw - _aw * s), 0.0).toDouble();
    ty = ty.clamp(math.min(0.0, vh - _ah * s), 0.0).toDouble();
    _transformation.value = Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1);
  }

  CadrePortrait _cadreActuel(double vw) {
    final m = _transformation.value.storage;
    final s = m[0];
    final l = vw / s / _f;
    return CadrePortrait(-m[12] / s / _f, -m[13] / s / _f, l, l * 4 / 3);
  }

  /// Agrandir (k > 1) ou réduire autour du centre du cadre.
  void _zoom(double k, double vw) {
    final m = _transformation.value.storage;
    final s = m[0];
    final s2 = (s * k).clamp(_echelleMin(vw), _echelleMin(vw) * 8).toDouble();
    final cx = (vw / 2 - m[12]) / s, cy = (vw * 2 / 3 - m[13]) / s;
    _placer(s2, vw / 2 - cx * s2, vw * 2 / 3 - cy * s2, vw);
  }

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Cadrer la photo'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _largeurVue == null ? null : () => Navigator.pop(context, _cadreActuel(_largeurVue!)),
                child: const Text('Utiliser'),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(builder: (context, c) {
          // Le cadre : aussi grand que l'écran le permet, sans dépasser 380 px de large.
          final vw = math.min(c.maxWidth - 32, (c.maxHeight - 170) * 3 / 4).clamp(160.0, 380.0).floorToDouble();
          if (_largeurVue != vw) {
            final avant = _largeurVue;
            final cadre = avant == null ? _p.cadre : _cadreActuel(avant);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _largeurVue = vw);
              _appliquer(cadre, vw);
            });
          }
          final vh = vw * 4 / 3;
          final schema = Theme.of(context).colorScheme;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Column(children: [
                Text('Le visage est placé tout seul. Faites glisser la photo, écartez deux doigts '
                    '(ou la molette) pour ajuster : le visage dans l\'ovale.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: schema.onSurfaceVariant)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: vw,
                    height: vh,
                    child: Stack(children: [
                      Positioned.fill(
                        child: Container(
                          color: Colors.black,
                          child: _largeurVue == null
                              ? null
                              : InteractiveViewer(
                                  transformationController: _transformation,
                                  constrained: false,
                                  boundaryMargin: EdgeInsets.zero,
                                  minScale: _echelleMin(vw),
                                  maxScale: _echelleMin(vw) * 8,
                                  child: SizedBox(
                                    width: _aw,
                                    height: _ah,
                                    child: Image.memory(_p.apercu, fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true),
                                  ),
                                ),
                        ),
                      ),
                      const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _GuideVisage()))),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  IconButton.outlined(
                      tooltip: 'Réduire', onPressed: _largeurVue == null ? null : () => _zoom(1 / 1.15, vw), icon: const Icon(Icons.zoom_out)),
                  IconButton.outlined(
                      tooltip: 'Agrandir', onPressed: _largeurVue == null ? null : () => _zoom(1.15, vw), icon: const Icon(Icons.zoom_in)),
                  OutlinedButton.icon(
                    onPressed: _largeurVue == null ? null : () => _appliquer(_p.cadre, vw),
                    icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
                    label: const Text('Recentrer'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _largeurVue == null ? null : () => _appliquer(cadreParDefaut(_p.image.width, _p.image.height), vw),
                    icon: const Icon(Icons.crop_free, size: 18),
                    label: const Text('Photo entière'),
                  ),
                ]),
              ]),
            ),
          );
        }),
      );
}

/// L'ovale du visage et les bords du cadre, en blanc sur la photo.
class _GuideVisage extends CustomPainter {
  const _GuideVisage();

  @override
  void paint(Canvas canvas, Size t) {
    final trait = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: .85);
    // Tête : 12 % sous le haut, environ 46 % de la largeur et 45 % de la hauteur.
    canvas.drawOval(Rect.fromLTWH(t.width * .27, t.height * .11, t.width * .46, t.height * .45), trait);
    canvas.drawRect(Offset.zero & t, trait..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_GuideVisage ancien) => false;
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

/// Une photo 3:4 dans un rond ou un carré : on garde le haut (le visage), pas le milieu.
const alignementVisage = Alignment(0, -.45);

/// Photo dans un rond, le visage au centre.
class VignetteRonde extends StatelessWidget {
  const VignetteRonde({super.key, required this.image, required this.taille});

  final ImageProvider image;
  final double taille;

  @override
  Widget build(BuildContext context) => ClipOval(
        child: Image(image: image, width: taille, height: taille, fit: BoxFit.cover, alignment: alignementVisage, filterQuality: FilterQuality.medium),
      );
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
          : Image(image: _image!, fit: BoxFit.cover, alignment: alignementVisage, width: double.infinity, height: double.infinity);
    }
    return _image == null
        ? Initiales(widget.nom, taille: widget.taille)
        : VignetteRonde(image: _image!, taille: widget.taille);
  }
}

/// La photo d'un élève qu'on agrandit sans toucher à la ligne qui la contient :
/// on la touche, elle s'ouvre en grand (zoom à deux doigts ou à la molette) ; sur
/// ordinateur, le survol en montre un aperçu. Sans photo : les initiales, sans geste.
class PhotoAgrandissable extends StatelessWidget {
  const PhotoAgrandissable({super.key, required this.eleveId, required this.nom, required this.version, this.taille = 40, this.changer});

  final String eleveId;
  final String nom;
  final String? version;
  final double taille;
  final VoidCallback? changer;

  @override
  Widget build(BuildContext context) {
    final photo = PhotoEleve(eleveId: eleveId, nom: nom, version: version, taille: taille);
    final v = version;
    if (v == null) return photo;
    return Tooltip(
      waitDuration: const Duration(milliseconds: 350),
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16)]),
      richMessage: WidgetSpan(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 180, height: 240, child: PhotoEleve(eleveId: eleveId, nom: nom, version: v, carre: true)),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => voirPhotoEleve(context, eleveId: eleveId, nom: nom, version: v, changer: changer),
          child: photo,
        ),
      ),
    );
  }
}

/// La photo d'un élève en grand, plein écran, qu'on peut agrandir avec deux doigts
/// (ou la molette) ; « Changer la photo » si on en a le droit.
Future<void> voirPhotoEleve(BuildContext context,
    {required String eleveId, required String nom, required String version, VoidCallback? changer}) async {
  var image = _cachePhotos[eleveId]?.$1 == version ? _cachePhotos[eleveId]!.$2 : null;
  if (image == null) {
    final p = await db.getOptional('SELECT image FROM photos_eleves WHERE eleve_id = ?', [eleveId]);
    if (p == null) return;
    try {
      image = MemoryImage(base64Decode(p['image'] as String));
      _cachePhotos[eleveId] = (version, image);
    } catch (_) {
      return;
    }
  }
  if (!context.mounted) return;
  final img = image;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: Image(image: img, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            top: 4,
            child: Row(children: [
              IconButton(
                tooltip: 'Fermer',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(nom,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              if (changer != null)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: () {
                    Navigator.pop(context);
                    changer();
                  },
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('Changer'),
                ),
            ]),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Text('Écartez deux doigts (ou la molette) pour agrandir',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 12)),
          ),
        ]),
      ),
    ),
  );
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
