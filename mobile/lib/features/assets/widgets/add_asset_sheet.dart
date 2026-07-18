import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import '../../../app.dart';
import '../../../core/models/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../billing/widgets/credits_exhausted_dialog.dart';

/// Mirrors the backend's `app.services.asset_writer._slugify` exactly:
/// lowercase -> strip non [a-z0-9 -] -> trim -> collapse whitespace to '-'.
/// Kept in sync with that function — see its docstring.
String slugifyAssetName(String name) {
  final lowered = name.toLowerCase();
  final stripped = lowered.replaceAll(RegExp(r'[^a-z0-9\s-]'), '').trim();
  return stripped.replaceAll(RegExp(r'\s+'), '-');
}

/// Opens the Add Asset Sheet (Screen 9a, FEAT-033–036).
///
/// [scope] is `null` for the global "Global Assets" section (Reference tab
/// hidden — a global asset cannot itself be a reference, FEAT-013) or a
/// scene number for a "Scene N" section (all three tabs shown).
Future<void> showAddAssetSheet(
  BuildContext context, {
  required String projectSlug,
  int? scope,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AddAssetSheet(projectSlug: projectSlug, scope: scope),
  );
}

/// Add Asset Sheet (Screen 9a) — long-press entry point (FEAT-033) for
/// creating a new asset from an uploaded image (FEAT-034), a typed
/// description (FEAT-035), or a reference to an existing asset (FEAT-036).
///
/// Dismissing without completing a tab's flow discards all input — no
/// Firestore document is created until the user explicitly saves.
class AddAssetSheet extends StatefulWidget {
  const AddAssetSheet({super.key, required this.projectSlug, this.scope});

  final String projectSlug;

  /// Null = global scope (`assets/`). Otherwise the scene number
  /// (`scenes/{scope}/assets/`).
  final int? scope;

  bool get isGlobal => scope == null;

  @override
  State<AddAssetSheet> createState() => _AddAssetSheetState();
}

class _AddAssetSheetState extends State<AddAssetSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: widget.isGlobal ? 2 : 3,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String get _collectionPath {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final projectPath = 'users/$uid/projects/${widget.projectSlug}';
    return widget.isGlobal
        ? '$projectPath/assets'
        : '$projectPath/scenes/${widget.scope}/assets';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isGlobal
        ? 'Add Global Asset'
        : 'Add Asset to Scene ${widget.scope}';

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title, style: AppTextStyles.h3(context)),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: [
                const Tab(text: 'Image'),
                const Tab(text: 'Text'),
                if (!widget.isGlobal) const Tab(text: 'Reference'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _ImageTab(
                    projectSlug: widget.projectSlug,
                    collectionPath: _collectionPath,
                    relativePathPrefix:
                        widget.isGlobal ? 'assets' : 'scenes/${widget.scope}/assets',
                    scrollController: scrollController,
                  ),
                  _TextTab(
                    collectionPath: _collectionPath,
                    scrollController: scrollController,
                  ),
                  if (!widget.isGlobal)
                    _ReferenceTab(
                      projectSlug: widget.projectSlug,
                      currentScope: widget.scope!,
                      collectionPath: _collectionPath,
                      scrollController: scrollController,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Text tab (FEAT-035) ─────────────────────────────────────────────────────

class _TextTab extends StatefulWidget {
  const _TextTab({required this.collectionPath, required this.scrollController});

  final String collectionPath;
  final ScrollController scrollController;

  @override
  State<_TextTab> createState() => _TextTabState();
}

class _TextTabState extends State<_TextTab> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  AssetType _type = AssetType.character;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final description = _descController.text.trim();
    if (name.isEmpty || description.isEmpty) {
      setState(() => _error = 'Name and description are required.');
      return;
    }

    final slug = slugifyAssetName(name);
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final ref = FirebaseFirestore.instance.doc('${widget.collectionPath}/$slug');
      final existing = await ref.get();
      if (existing.exists) {
        setState(() {
          _saving = false;
          _error = 'An asset named "$name" already exists in this scope.';
        });
        return;
      }
      await ref.set({
        'name': name,
        'type': _type.value,
        'description': description,
        'prompt_body': null,
        'gcs_image_path': null,
        'source': 'manual_text',
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(AppSpacing.s4),
      children: [
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: AppSpacing.s3),
        _AssetTypeSelector(
          selected: _type,
          onChanged: (t) => setState(() => _type = t),
        ),
        const SizedBox(height: AppSpacing.s3),
        TextField(
          controller: _descController,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Description'),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.s2),
          Text(_error!, style: TextStyle(color: Colors.red.shade400)),
        ],
        const SizedBox(height: AppSpacing.s4),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ── Reference tab (FEAT-036) ────────────────────────────────────────────────

class _ReferenceTab extends StatefulWidget {
  const _ReferenceTab({
    required this.projectSlug,
    required this.currentScope,
    required this.collectionPath,
    required this.scrollController,
  });

  final String projectSlug;
  final int currentScope;
  final String collectionPath;
  final ScrollController scrollController;

  @override
  State<_ReferenceTab> createState() => _ReferenceTabState();
}

class _ReferenceTabState extends State<_ReferenceTab> {
  String _query = '';
  String? _error;
  bool _saving = false;
  final _descController = TextEditingController();

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  String get _projectPath {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return 'users/$uid/projects/${widget.projectSlug}';
  }

  /// Loads every candidate asset — global `assets/` plus every scene's
  /// `assets/` subcollection — excluding assets whose own `name` already
  /// starts with `@` (no chained references, FEAT-036).
  Future<List<_ReferenceCandidate>> _loadCandidates() async {
    final fs = FirebaseFirestore.instance;
    final candidates = <_ReferenceCandidate>[];

    final globalDocs = await fs.collection('$_projectPath/assets').get();
    for (final doc in globalDocs.docs) {
      final name = doc.data()['name'] as String? ?? doc.id;
      if (name.startsWith('@')) continue;
      candidates.add(_ReferenceCandidate(
        scope: 0,
        slug: doc.id,
        name: name,
        type: doc.data()['type'] as String? ?? 'character',
        gcsImagePath: doc.data()['gcs_image_path'] as String?,
      ));
    }

    final scenes = await fs.collection('$_projectPath/scenes').get();
    for (final sceneDoc in scenes.docs) {
      final sceneNum = int.tryParse(sceneDoc.id) ?? 0;
      final assetDocs =
          await fs.collection('$_projectPath/scenes/${sceneDoc.id}/assets').get();
      for (final doc in assetDocs.docs) {
        final name = doc.data()['name'] as String? ?? doc.id;
        if (name.startsWith('@')) continue;
        candidates.add(_ReferenceCandidate(
          scope: sceneNum,
          slug: doc.id,
          name: name,
          type: doc.data()['type'] as String? ?? 'character',
          gcsImagePath: doc.data()['gcs_image_path'] as String?,
        ));
      }
    }
    return candidates;
  }

  Future<void> _select(_ReferenceCandidate candidate) async {
    final referenceName = '@/scenes/${candidate.scope}/${candidate.slug}';
    final description = _descController.text.trim();
    // A duplicate reference is a warning, not a block (FEAT-036) — the slug
    // for the new doc is derived from the referenced name plus a short
    // discriminator so two variants of the same source can coexist.
    final newSlug =
        '${candidate.slug}-ref-${DateTime.now().millisecondsSinceEpoch % 100000}';

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await FirebaseFirestore.instance.doc('${widget.collectionPath}/$newSlug').set({
        'name': referenceName,
        'type': candidate.type,
        'description': description,
        'prompt_body': null,
        'gcs_image_path': null,
        'source': 'manual_reference',
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          child: Column(
            children: [
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Search assets',
                  prefixIcon: Icon(LucideIcons.search),
                ),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
              ),
              const SizedBox(height: AppSpacing.s2),
              TextField(
                controller: _descController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional — leave blank for pass-through)',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s2),
                  child: Text(_error!, style: TextStyle(color: Colors.red.shade400)),
                ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<_ReferenceCandidate>>(
            future: _loadCandidates(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final filtered = snapshot.data!
                  .where((c) => c.name.toLowerCase().contains(_query))
                  .toList();
              if (filtered.isEmpty) {
                return const Center(child: Text('No assets found.'));
              }
              return ListView.builder(
                controller: widget.scrollController,
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final c = filtered[i];
                  return ListTile(
                    leading: Icon(_iconForType(c.type)),
                    title: Text(c.name),
                    subtitle: Text(c.type),
                    enabled: !_saving,
                    onTap: () => _select(c),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  IconData _iconForType(String type) => switch (type) {
        'background' => LucideIcons.image,
        'object' => LucideIcons.box,
        _ => LucideIcons.user,
      };
}

class _ReferenceCandidate {
  _ReferenceCandidate({
    required this.scope,
    required this.slug,
    required this.name,
    required this.type,
    this.gcsImagePath,
  });

  final int scope;
  final String slug;
  final String name;
  final String type;
  final String? gcsImagePath;
}

// ── Image tab (FEAT-034) ────────────────────────────────────────────────────

class _ImageTab extends StatefulWidget {
  const _ImageTab({
    required this.projectSlug,
    required this.collectionPath,
    required this.relativePathPrefix,
    required this.scrollController,
  });

  final String projectSlug;
  final String collectionPath;

  /// Relative asset path prefix below the project root — `assets` for
  /// global scope, or `scenes/{n}/assets` for scene-local scope. Combined
  /// with the asset slug to build the `asset_path` sent to /image-prompt
  /// and /image (see docs/ArkMask/schema.md).
  final String relativePathPrefix;
  final ScrollController scrollController;

  @override
  State<_ImageTab> createState() => _ImageTabState();
}

class _ImageTabState extends State<_ImageTab> {
  static const int _maxUploadBytes = 10 * 1024 * 1024; // 10 MB (FEAT-034)
  static const Set<String> _allowedExtensions = {'png', 'jpg', 'jpeg'};

  XFile? _picked;
  AssetType _type = AssetType.character;
  bool _styleAdapted = false;
  final _nameController = TextEditingController();
  final _descController = TextEditingController();

  bool _uploading = false;
  bool _describing = false;
  bool _saving = false;
  String? _error;
  String? _uploadedGcsPath;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 90);
    if (picked == null) return;

    final ext = picked.path.split('.').last.toLowerCase();
    if (!_allowedExtensions.contains(ext)) {
      setState(() => _error = 'Unsupported file type. Use PNG or JPEG.');
      return;
    }
    final size = await picked.length();
    if (size > _maxUploadBytes) {
      setState(() => _error = 'File exceeds the 10 MB size limit.');
      return;
    }

    setState(() {
      _picked = picked;
      _error = null;
      _uploadedGcsPath = null;
      _descController.clear();
    });

    await _uploadAndDescribe(picked, ext);
  }

  Future<void> _uploadAndDescribe(XFile picked, String ext) async {
    final apiClient = ArkMaskServices.of(context).apiClient;
    final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    // Object path derived per docs/ArkMask/schema.md POST /media/upload-url:
    // final image directly if not style-adapting, else original.<ext> as a
    // conditioning reference only. The slug is a placeholder here — the real
    // asset slug is only known once the name is entered; a UUID-scoped temp
    // path avoids colliding with the eventual asset document.
    final tempSlug = 'tmp-${DateTime.now().millisecondsSinceEpoch}';
    final objectPath = _styleAdapted
        ? 'assets/$tempSlug/original.$ext'
        : 'assets/$tempSlug/image.png';

    setState(() => _uploading = true);
    try {
      final (uploadUrl, gcsPath) = await apiClient.getUploadUrl(
        projectSlug: widget.projectSlug,
        objectPath: objectPath,
        contentType: contentType,
      );
      final bytes = await File(picked.path).readAsBytes();
      await apiClient.uploadToPresignedUrl(
        uploadUrl: uploadUrl,
        bytes: bytes,
        contentType: contentType,
      );
      setState(() {
        _uploading = false;
        _uploadedGcsPath = gcsPath;
        _describing = true;
      });

      final description = await apiClient.describeImage(
        gcsPath: gcsPath,
        type: _type.value,
      );
      if (!mounted) return;
      setState(() {
        _describing = false;
        _descController.text = description;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _describing = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final description = _descController.text.trim();
    if (_uploadedGcsPath == null || name.isEmpty || description.isEmpty) {
      setState(() => _error = 'Pick an image, then fill in name and description.');
      return;
    }

    final apiClient = ArkMaskServices.of(context).apiClient;
    final slug = slugifyAssetName(name);
    final assetPath = '${widget.relativePathPrefix}/$slug';

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final docRef = FirebaseFirestore.instance.doc('${widget.collectionPath}/$slug');

      if (!_styleAdapted) {
        // Uploaded image is used as-is — already at its final GCS path
        // (image.png was the direct upload target), so just write the doc.
        await docRef.set({
          'name': name,
          'type': _type.value,
          'description': description,
          'prompt_body': null,
          'gcs_image_path': _uploadedGcsPath,
          'source': 'manual_image',
          'style_adapted': false,
          'original_upload_gcs_path': null,
          'created_at': FieldValue.serverTimestamp(),
          'updated_at': FieldValue.serverTimestamp(),
        });
      } else {
        // Write the doc first (prompt_body/gcs_image_path null), then run
        // the standard /image-prompt + /image pipeline with the uploaded
        // photo as the conditioning reference (FEAT-034).
        await docRef.set({
          'name': name,
          'type': _type.value,
          'description': description,
          'prompt_body': null,
          'gcs_image_path': null,
          'source': 'manual_image',
          'style_adapted': true,
          'original_upload_gcs_path': _uploadedGcsPath,
          'created_at': FieldValue.serverTimestamp(),
          'updated_at': FieldValue.serverTimestamp(),
        });

        await apiClient.generateImagePrompt(
          projectSlug: widget.projectSlug,
          assetFirestorePath: assetPath,
          name: name,
          type: _type.value,
          description: description,
        );
        // The prompt job writes prompt_body asynchronously; /image needs a
        // non-empty prompt_body already present server-side, so the image
        // job is enqueued from the Asset Editor once the Firestore listener
        // shows prompt_body populated — mirroring FEAT-011/FEAT-012's normal
        // sequencing rather than racing the two calls here.
      }

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _uploading || _describing || _saving;

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(AppSpacing.s4),
      children: [
        // Type and style-adapt choices are set BEFORE picking an image —
        // both feed the upload/describe call fired the instant a photo is
        // selected (asset type for /image-describe, style-adapt for the
        // upload's GCS object naming), so there is no image-picked window
        // during which these settings can still be silently overridden.
        _AssetTypeSelector(
          selected: _type,
          onChanged: (t) => setState(() => _type = t),
        ),
        const SizedBox(height: AppSpacing.s3),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Adapt to story asset style?'),
          subtitle: Text(
            _styleAdapted
                ? 'A new image will be generated in the project\'s art style, using your photo as a reference (${CreditCost.imagePrompt + CreditCost.imageGeneration} credits). Set this before picking a photo below.'
                : 'The uploaded photo is used as-is with no regeneration. Set this before picking a photo below.',
          ),
          value: _styleAdapted,
          onChanged: _picked != null
              ? null
              : (v) => setState(() => _styleAdapted = v),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (_picked == null)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  icon: const Icon(LucideIcons.image),
                  label: const Text('Gallery'),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickImage(ImageSource.camera),
                  icon: const Icon(LucideIcons.camera),
                  label: const Text('Camera'),
                ),
              ),
            ],
          )
        else ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSizing.radiusMd),
            child: Image.file(File(_picked!.path), height: 160, fit: BoxFit.cover),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              // Only way back to the type/style-adapt choices, which lock
              // once a photo is picked (see the switch above) — lets the
              // user reconsider those without leaving and reopening the
              // whole sheet. Discards the in-flight upload/description;
              // the orphaned temp GCS object is harmless and unreferenced.
              onPressed: (_uploading || _describing || _saving)
                  ? null
                  : () => setState(() {
                        _picked = null;
                        _uploadedGcsPath = null;
                        _descController.clear();
                        _error = null;
                      }),
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: const Text('Change photo'),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s3),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (_describing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.s2),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: AppSpacing.s2),
                Text('Generating description...'),
              ],
            ),
          )
        else
          TextField(
            controller: _descController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description (generated — editable)',
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.s2),
          Text(_error!, style: TextStyle(color: Colors.red.shade400)),
        ],
        const SizedBox(height: AppSpacing.s4),
        ElevatedButton(
          onPressed: busy || _uploadedGcsPath == null
              ? null
              : () async {
                  try {
                    await _save();
                  } catch (_) {
                    if (context.mounted) showCreditsExhaustedDialog(context);
                  }
                },
          child: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ── Shared widgets ───────────────────────────────────────────────────────────

class _AssetTypeSelector extends StatelessWidget {
  const _AssetTypeSelector({required this.selected, required this.onChanged});

  final AssetType selected;
  final ValueChanged<AssetType> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDark : AppColors.primaryLight;
    final onPrimaryColor = isDark ? AppColors.primaryOnDark : AppColors.primaryOnLight;
    return Wrap(
      spacing: AppSpacing.s2,
      children: AssetType.values.map((type) {
        final isSelected = type == selected;
        return ChoiceChip(
          label: Text(type.name),
          // Solid primary fill (not a subtle tint) + on-primary text so the
          // selected state reads clearly against both light and dark
          // surfaces — a low-alpha tint here was too close to the chip's
          // unselected background to tell apart at a glance.
          labelStyle: TextStyle(
            color: isSelected ? onPrimaryColor : null,
            fontWeight: isSelected ? FontWeight.w600 : null,
          ),
          selected: isSelected,
          selectedColor: primaryColor,
          showCheckmark: false,
          side: isSelected
              ? BorderSide(color: primaryColor)
              : null,
          onSelected: (_) => onChanged(type),
        );
      }).toList(),
    );
  }
}
