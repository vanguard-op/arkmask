import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../models/models.dart';

/// Characters not allowed in project directory names.
final _invalidNameChars = RegExp(r'[/\\:*?"<>|]');

/// On-device filesystem operations for ArkMask projects.
///
/// Projects live directly inside the user-chosen vault directory:
/// ```
/// <vaultRoot>/
///   <projectName>/
///     story.mdx
///     final.mp4          (written at export time)
///     assets/
///       <assetName>/
///         prompt.mdx
///         image.png      (optional — written after image generation)
///     scenes/
///       <N>/
///         assets/
///           <assetName>/
///             prompt.mdx
///             image.png  (optional)
///         ark.mdx
///         video.mp4      (optional — written after video generation)
/// ```
///
/// The vault root path is set by calling [initialize] with the path chosen
/// by the user in [VaultSetupScreen]. Call [reinitialize] when the vault is
/// changed at runtime (e.g. from Settings).
class ProjectFileService {
  ProjectFileService();

  /// The vault root — all project directories live directly inside this.
  late Directory _projectsRoot;
  bool _initialized = false;

  /// The absolute path to the current vault root directory.
  String get projectsRootPath {
    _assertInit();
    return _projectsRoot.path;
  }

  /// Initialises the service with [vaultRootPath] as the projects root.
  ///
  /// Creates the directory if it does not exist. Safe to call multiple times
  /// with the same path — subsequent calls are no-ops.
  Future<void> initialize(String vaultRootPath) async {
    if (_initialized) return;
    _projectsRoot = Directory(vaultRootPath);
    if (!await _projectsRoot.exists()) {
      await _projectsRoot.create(recursive: true);
    }
    _initialized = true;
  }

  /// Switches the vault root to [vaultRootPath] at runtime.
  ///
  /// Called when the user changes the vault from Settings. Any cubits that
  /// hold project data should be refreshed after this call.
  Future<void> reinitialize(String vaultRootPath) async {
    _initialized = false;
    await initialize(vaultRootPath);
  }

  void _assertInit() {
    if (!_initialized) throw StateError('Call initialize() first.');
  }

  // ── Project list ──────────────────────────────────────────────────────────

  /// Returns metadata for all projects stored on device, sorted by most
  /// recently modified descending.
  Future<List<ProjectMeta>> listProjects() async {
    _assertInit();
    final dirs = await _projectsRoot
        .list()
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();

    final metas = <ProjectMeta>[];
    for (final dir in dirs) {
      final meta = await _readProjectMeta(dir);
      metas.add(meta);
    }

    metas.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return metas;
  }

  Future<ProjectMeta> _readProjectMeta(Directory dir) async {
    final name = p.basename(dir.path);
    var lastModified = (await dir.stat()).modified;
    var sceneCount = 0;
    var completedSceneCount = 0;

    final scenesDir = Directory(p.join(dir.path, 'scenes'));
    if (await scenesDir.exists()) {
      await for (final entry in scenesDir.list()) {
        if (entry is! Directory) continue;
        sceneCount++;
        final videoFile = File(p.join(entry.path, 'video.mp4'));
        if (await videoFile.exists()) completedSceneCount++;
        final stat = await entry.stat();
        if (stat.modified.isAfter(lastModified)) lastModified = stat.modified;
      }
    }

    return ProjectMeta(
      name: name,
      directoryPath: dir.path,
      lastModified: lastModified,
      sceneCount: sceneCount,
      completedSceneCount: completedSceneCount,
    );
  }

  // ── Project creation ───────────────────────────────────────────────────────

  /// Validates and sanitizes a project name.
  ///
  /// Returns null if the name is valid; otherwise an error message string.
  String? validateProjectName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Project name is required.';
    if (trimmed.length > 60) return 'Project name must be 60 characters or fewer.';
    if (_invalidNameChars.hasMatch(trimmed)) {
      return 'Name cannot contain / \\ : * ? " < > |';
    }
    return null;
  }

  /// Whether a project directory with [name] already exists on device.
  Future<bool> projectExists(String name) async {
    _assertInit();
    return Directory(p.join(_projectsRoot.path, name.trim())).exists();
  }

  /// Creates the project directory structure and returns the [ProjectMeta].
  ///
  /// Throws [FileSystemException] if the directory cannot be created.
  Future<ProjectMeta> createProject(String name) async {
    _assertInit();
    final sanitized = name.trim();
    final projectDir = Directory(p.join(_projectsRoot.path, sanitized));

    // Create required subdirectories.
    await Directory(p.join(projectDir.path, 'assets')).create(recursive: true);
    await Directory(p.join(projectDir.path, 'scenes')).create(recursive: true);

    // Create empty story.mdx.
    await File(p.join(projectDir.path, 'story.mdx')).writeAsString('');

    return _readProjectMeta(projectDir);
  }

  // ── Project deletion ───────────────────────────────────────────────────────

  /// Permanently deletes the project directory and all its contents.
  Future<void> deleteProject(String projectName) async {
    _assertInit();
    final dir = Directory(p.join(_projectsRoot.path, projectName));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // ── File tree ─────────────────────────────────────────────────────────────

  /// Returns a [ProjectTree] representing the current on-device file structure
  /// for the given project.
  Future<ProjectTree> readProjectTree(String projectName) async {
    _assertInit();
    final projectDir = Directory(p.join(_projectsRoot.path, projectName));

    final storyFile = File(p.join(projectDir.path, 'story.mdx'));
    final storyExists = await storyFile.exists();

    final List<AssetNode> globalAssets = [];
    final assetsDir = Directory(p.join(projectDir.path, 'assets'));
    if (await assetsDir.exists()) {
      await for (final entry in assetsDir.list()) {
        if (entry is! Directory) continue;
        final node = await _readAssetNode(entry, isGlobal: true);
        globalAssets.add(node);
      }
    }

    final List<SceneNode> scenes = [];
    final scenesDir = Directory(p.join(projectDir.path, 'scenes'));
    if (await scenesDir.exists()) {
      final entries = await scenesDir.list().toList();
      // Sort scene directories numerically.
      entries.sort((a, b) {
        final na = int.tryParse(p.basename(a.path)) ?? 0;
        final nb = int.tryParse(p.basename(b.path)) ?? 0;
        return na.compareTo(nb);
      });
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final node = await _readSceneNode(entry);
        scenes.add(node);
      }
    }

    return ProjectTree(
      projectName: projectName,
      directoryPath: projectDir.path,
      storyExists: storyExists,
      storyHasContent: storyExists && (await storyFile.readAsString()).trim().isNotEmpty,
      globalAssets: globalAssets,
      scenes: scenes,
    );
  }

  Future<AssetNode> _readAssetNode(Directory assetDir, {required bool isGlobal, int? sceneNumber}) async {
    final promptFile = File(p.join(assetDir.path, 'prompt.mdx'));
    final imageFile = File(p.join(assetDir.path, 'image.png'));

    // Default to directory basename; overridden by frontmatter `name` below so
    // that reference paths (e.g. "@/scenes/0/lyra") are preserved and shown.
    String name = p.basename(assetDir.path);
    String? description;
    bool hasPromptBody = false;
    AssetType? type;

    if (await promptFile.exists()) {
      final content = await promptFile.readAsString();
      final parsed = _parseMdxFrontmatter(content);
      // Use the frontmatter name when available — it may be a reference path.
      final frontmatterName = parsed['name'] as String?;
      if (frontmatterName != null && frontmatterName.isNotEmpty) {
        name = frontmatterName;
      }
      description = parsed['description'] as String?;
      hasPromptBody = content.contains('---') && content.split('---').length >= 3
          ? (content.split('---')[2].trim().isNotEmpty)
          : false;
      final typeStr = parsed['type'] as String?;
      if (typeStr != null) {
        type = AssetType.fromString(typeStr);
      }
    }

    return AssetNode(
      name: name,
      directoryPath: assetDir.path,
      isGlobal: isGlobal,
      sceneNumber: sceneNumber,
      type: type,
      description: description ?? '',
      hasPromptBody: hasPromptBody,
      hasImage: await imageFile.exists(),
    );
  }

  Future<SceneNode> _readSceneNode(Directory sceneDir) async {
    final numberStr = p.basename(sceneDir.path);
    final sceneNumber = int.tryParse(numberStr) ?? 0;

    final arkFile = File(p.join(sceneDir.path, 'ark.mdx'));
    final videoFile = File(p.join(sceneDir.path, 'video.mp4'));

    bool hasStoryboard = false;
    if (await arkFile.exists()) {
      final content = await arkFile.readAsString();
      // Body is populated if there's content after the frontmatter.
      hasStoryboard = content.contains('---') && content.split('---').length >= 3
          ? content.split('---')[2].trim().isNotEmpty
          : content.trim().isNotEmpty;
    }

    final List<AssetNode> sceneAssets = [];
    final sceneAssetsDir = Directory(p.join(sceneDir.path, 'assets'));
    if (await sceneAssetsDir.exists()) {
      await for (final entry in sceneAssetsDir.list()) {
        if (entry is! Directory) continue;
        final node = await _readAssetNode(entry, isGlobal: false, sceneNumber: sceneNumber);
        sceneAssets.add(node);
      }
    }

    return SceneNode(
      sceneNumber: sceneNumber,
      directoryPath: sceneDir.path,
      hasStoryboard: hasStoryboard,
      hasVideo: await videoFile.exists(),
      assets: sceneAssets,
    );
  }

  // ── Story file ────────────────────────────────────────────────────────────

  /// Reads the full content of `story.mdx` for a project.
  Future<String> readStory(String projectName) async {
    _assertInit();
    final file = File(p.join(_projectsRoot.path, projectName, 'story.mdx'));
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  /// Writes content to `story.mdx` for a project.
  Future<void> writeStory(String projectName, String content) async {
    _assertInit();
    final file = File(p.join(_projectsRoot.path, projectName, 'story.mdx'));
    await file.writeAsString(content);
  }

  // ── Asset directories (created after /assets response) ────────────────────

  /// Creates the directory structure for extracted assets on device.
  ///
  /// [assets] is the list of [ExtractedAsset] from the backend `/assets` response.
  Future<void> createAssetDirectories({
    required String projectName,
    required List<ExtractedAsset> assets,
  }) async {
    _assertInit();
    final projectDir = p.join(_projectsRoot.path, projectName);
    for (final asset in assets) {
      // Reference names (e.g. "@/scenes/0/lyra") contain slashes that would
      // create nested directories. Use only the last segment as the folder name
      // so the directory is always a single flat entry under `assets/`.
      final dirName = asset.name.contains('/') ? asset.name.split('/').last : asset.name;

      final dirPath = asset.isGlobal
          ? p.join(projectDir, 'assets', dirName)
          : p.join(projectDir, 'scenes', '${asset.sceneNumber}', 'assets', dirName);
      await Directory(dirPath).create(recursive: true);

      // Write initial prompt.mdx. Always quote `name` — values starting with
      // '@' are reserved in YAML and must be quoted or the parser returns null,
      // which would cause the reference path to be lost on read-back.
      final promptFile = File(p.join(dirPath, 'prompt.mdx'));
      await promptFile.writeAsString(
        '---\nname: "${_escapeYamlString(asset.name)}"\ntype: ${asset.type.value}\ndescription: "${_escapeYamlString(asset.description)}"\n---\n',
      );
    }
  }

  // ── Asset MDX ─────────────────────────────────────────────────────────────

  /// Reads `prompt.mdx` from [assetDirPath] and returns the parsed [AssetPrompt].
  ///
  /// Returns a blank [AssetPrompt] if the file does not exist or cannot be parsed.
  Future<AssetPrompt> readAssetPrompt(String assetDirPath) async {
    _assertInit();
    final file = File(p.join(assetDirPath, 'prompt.mdx'));
    if (!await file.exists()) {
      final name = p.basename(assetDirPath);
      return AssetPrompt(name: name, type: AssetType.character, description: '', promptBody: '');
    }
    final content = await file.readAsString();
    final fm = _parseMdxFrontmatter(content);
    final body = _parseMdxBody(content);
    return AssetPrompt(
      name: (fm['name'] as String?) ?? p.basename(assetDirPath),
      type: AssetType.fromString((fm['type'] as String?) ?? 'character'),
      description: (fm['description'] as String?) ?? '',
      promptBody: body,
    );
  }

  /// Writes [prompt] to `prompt.mdx` in [assetDirPath].
  Future<void> writeAssetPrompt(String assetDirPath, AssetPrompt prompt) async {
    _assertInit();
    final file = File(p.join(assetDirPath, 'prompt.mdx'));
    final content =
        '---\nname: "${_escapeYamlString(prompt.name)}"\ntype: ${prompt.type.value}\ndescription: "${_escapeYamlString(prompt.description)}"\n---\n${prompt.promptBody}';
    await file.writeAsString(content);
  }

  /// Saves raw image [bytes] as `image.png` inside [assetDirPath].
  Future<void> saveImageToAssetDir(String assetDirPath, List<int> bytes) async {
    _assertInit();
    final file = File(p.join(assetDirPath, 'image.png'));
    await file.writeAsBytes(bytes);
  }

  /// Returns the `image.png` [File] for [assetDirPath] (may not exist on disk).
  File imageFileForAsset(String assetDirPath) =>
      File(p.join(assetDirPath, 'image.png'));

  // ── Scene storyboard (ark.mdx) ─────────────────────────────────────────────

  /// Reads `ark.mdx` from [sceneDirPath] and returns the parsed [SceneStoryboard].
  Future<SceneStoryboard> readArkMdx(String sceneDirPath) async {
    _assertInit();
    final file = File(p.join(sceneDirPath, 'ark.mdx'));
    if (!await file.exists()) {
      final sceneNumber = int.tryParse(p.basename(sceneDirPath)) ?? 0;
      return SceneStoryboard(sceneNumber: sceneNumber, storyboardBody: '');
    }
    final content = await file.readAsString();
    final fm = _parseMdxFrontmatter(content);
    final body = _parseMdxBody(content);
    final sceneNumber = (fm['scene'] as int?) ?? (int.tryParse(p.basename(sceneDirPath)) ?? 0);
    return SceneStoryboard(sceneNumber: sceneNumber, storyboardBody: body);
  }

  /// Writes [storyboard] to `ark.mdx` in [sceneDirPath].
  Future<void> writeArkMdx(String sceneDirPath, SceneStoryboard storyboard) async {
    _assertInit();
    await Directory(sceneDirPath).create(recursive: true);
    final file = File(p.join(sceneDirPath, 'ark.mdx'));
    final content =
        '---\nscene: ${storyboard.sceneNumber}\n---\n${storyboard.storyboardBody}';
    await file.writeAsString(content);
  }

  /// Returns the `video.mp4` [File] for [sceneDirPath] (may not exist on disk).
  File videoFileForScene(String sceneDirPath) =>
      File(p.join(sceneDirPath, 'video.mp4'));

  // ── Utility ───────────────────────────────────────────────────────────────

  /// Extracts the MDX body (content after the closing `---` of frontmatter).
  String _parseMdxBody(String content) {
    final parts = content.split('---');
    if (parts.length < 3) return content.trim();
    return parts.sublist(2).join('---').trimLeft();
  }

  /// Repairs prompt.mdx files where the `name` field was written unquoted
  /// and contained a YAML-reserved character (`@`), causing the frontmatter
  /// parser to return `{}` and the name to fall back to the directory basename.
  ///
  /// Detects broken files by checking: if the parsed `name` equals the
  /// directory basename AND the raw frontmatter contains an unquoted `@` value.
  /// Rewrites the file with the name properly quoted so future reads are correct.
  ///
  /// Safe to call on startup; no-op when nothing is broken.
  Future<void> repairUnquotedRefNames(String projectName) async {
    _assertInit();
    final projectDir = Directory(p.join(_projectsRoot.path, projectName));
    if (!await projectDir.exists()) return;

    await for (final entity in projectDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (p.basename(entity.path) != 'prompt.mdx') continue;

      final content = await entity.readAsString();
      // Look for an unquoted @ value in the name field across any line.
      final hasUnquotedRef = content
          .split('\n')
          .any((line) => RegExp(r'^name:\s*@').hasMatch(line));
      if (!hasUnquotedRef) continue;

      // Re-quote the name field. Process line-by-line to avoid multiline regex.
      final fixed = content.split('\n').map((line) {
        final match = RegExp(r'^(name:\s*)(@.*)$').firstMatch(line);
        if (match == null) return line;
        return '${match[1]}"${match[2]}"';
      }).join('\n');
      await entity.writeAsString(fixed);
    }
  }

  /// Escapes double-quotes for YAML inline string values.
  String _escapeYamlString(String s) => s.replaceAll('"', '\\"');

  /// Parses YAML frontmatter from an MDX file string.
  ///
  /// Expects format: `---\n<yaml>\n---\n<body>`.
  Map<dynamic, dynamic> _parseMdxFrontmatter(String content) {
    final parts = content.split('---');
    if (parts.length < 3) return {};
    try {
      final yaml = loadYaml(parts[1].trim()) as Map?;
      return yaml ?? {};
    } catch (_) {
      return {};
    }
  }
}

// ── Tree node types ──────────────────────────────────────────────────────────

/// The entire file tree for one project, used to render the file browser.
class ProjectTree {
  const ProjectTree({
    required this.projectName,
    required this.directoryPath,
    required this.storyExists,
    required this.storyHasContent,
    required this.globalAssets,
    required this.scenes,
  });

  final String projectName;
  final String directoryPath;
  final bool storyExists;
  final bool storyHasContent;
  final List<AssetNode> globalAssets;
  final List<SceneNode> scenes;

  bool get isBlank => globalAssets.isEmpty && scenes.isEmpty;
}

/// Represents an asset directory in the file tree (global or scene-local).
class AssetNode {
  const AssetNode({
    required this.name,
    required this.directoryPath,
    required this.isGlobal,
    this.sceneNumber,
    this.type,
    required this.description,
    required this.hasPromptBody,
    required this.hasImage,
  });

  final String name;
  final String directoryPath;
  final bool isGlobal;
  final int? sceneNumber;
  final AssetType? type;

  /// Empty description means this scene-local asset uses the global image.
  final String description;
  final bool hasPromptBody;
  final bool hasImage;

  /// True when this is a scene-local asset with empty description
  /// (pass-through to global asset image).
  bool get isPassThrough => !isGlobal && description.isEmpty;
}

/// Represents a scene directory in the file tree.
class SceneNode {
  const SceneNode({
    required this.sceneNumber,
    required this.directoryPath,
    required this.hasStoryboard,
    required this.hasVideo,
    required this.assets,
  });

  final int sceneNumber;
  final String directoryPath;
  final bool hasStoryboard;
  final bool hasVideo;
  final List<AssetNode> assets;
}
