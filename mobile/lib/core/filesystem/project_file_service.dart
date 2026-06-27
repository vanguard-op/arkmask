import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import '../models/models.dart';

/// Characters not allowed in project directory names.
final _invalidNameChars = RegExp(r'[/\\:*?"<>|]');

/// On-device filesystem operations for ArkMask projects.
///
/// All project files live under `<AppDocuments>/arkmask_projects/`.
/// The structure per project is:
/// ```
/// <projectName>/
///   story.mdx
///   final.mp4          (written at export time)
///   assets/
///     <assetName>/
///       prompt.mdx
///       image.png      (optional — written after image generation)
///   scenes/
///     <N>/
///       assets/
///         <assetName>/
///           prompt.mdx
///           image.png  (optional)
///       ark.mdx
///       video.mp4      (optional — written after video generation)
/// ```
class ProjectFileService {
  ProjectFileService();

  /// Root directory for all ArkMask project directories.
  late final Directory _projectsRoot;
  bool _initialized = false;

  /// Must be called once before using any other method.
  Future<void> initialize() async {
    if (_initialized) return;
    final docs = await getApplicationDocumentsDirectory();
    _projectsRoot = Directory(p.join(docs.path, 'arkmask_projects'));
    if (!await _projectsRoot.exists()) {
      await _projectsRoot.create(recursive: true);
    }
    _initialized = true;
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
    final name = p.basename(assetDir.path);
    final promptFile = File(p.join(assetDir.path, 'prompt.mdx'));
    final imageFile = File(p.join(assetDir.path, 'image.png'));

    String? description;
    bool hasPromptBody = false;
    AssetType? type;

    if (await promptFile.exists()) {
      final content = await promptFile.readAsString();
      final parsed = _parseMdxFrontmatter(content);
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
      final dirPath = asset.isGlobal
          ? p.join(projectDir, 'assets', asset.name)
          : p.join(projectDir, 'scenes', '${asset.sceneNumber}', 'assets', asset.name);
      await Directory(dirPath).create(recursive: true);

      // Write initial prompt.mdx with frontmatter populated, empty body.
      final promptFile = File(p.join(dirPath, 'prompt.mdx'));
      await promptFile.writeAsString(
        '---\nname: ${asset.name}\ntype: ${asset.type.value}\ndescription: "${asset.description}"\n---\n',
      );
    }
  }

  // ── Utility ───────────────────────────────────────────────────────────────

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
