// Data models for ArkMask, derived from docs/ArkMask/schema.md.
//
// Firestore-backed project models (ProjectDocument, AssetDocument,
// SceneDocument) replace the filesystem-based ProjectMeta that was used before
// the cloud-first architecture. ProjectMeta is kept for backward compat with
// Phase 2 cubits until they are migrated to Firestore in Phase 2.

enum AssetType {
  character,
  background,
  object;

  String get value => name;

  static AssetType fromString(String s) => AssetType.values.firstWhere(
        (t) => t.name == s,
        orElse: () => AssetType.character,
      );
}

class AssetPrompt {
  const AssetPrompt({
    required this.name,
    required this.type,
    required this.description,
    required this.promptBody,
  });

  final String name;
  final AssetType type;
  final String description;
  final String promptBody;

  bool get isPassThrough => description.isEmpty;

  AssetPrompt copyWith({String? name, AssetType? type, String? description, String? promptBody}) =>
      AssetPrompt(
        name: name ?? this.name,
        type: type ?? this.type,
        description: description ?? this.description,
        promptBody: promptBody ?? this.promptBody,
      );
}

class SceneStoryboard {
  const SceneStoryboard({required this.sceneNumber, required this.storyboardBody});

  final int sceneNumber;
  final String storyboardBody;

  bool get isEmpty => storyboardBody.isEmpty;

  SceneStoryboard copyWith({int? sceneNumber, String? storyboardBody}) =>
      SceneStoryboard(
        sceneNumber: sceneNumber ?? this.sceneNumber,
        storyboardBody: storyboardBody ?? this.storyboardBody,
      );
}

class ExtractedAsset {
  const ExtractedAsset({required this.name, required this.type, required this.sceneNumber, required this.description});

  final String name;
  final AssetType type;
  final int sceneNumber;
  final String description;

  bool get isGlobal => sceneNumber == 0;

  factory ExtractedAsset.fromJson(Map<String, dynamic> json) => ExtractedAsset(
        name: json['name'] as String,
        type: AssetType.fromString(json['type'] as String),
        sceneNumber: json['scene_number'] as int,
        description: json['description'] as String,
      );
}

class AssetsResponse {
  const AssetsResponse({required this.assets});
  final List<ExtractedAsset> assets;

  factory AssetsResponse.fromJson(Map<String, dynamic> json) => AssetsResponse(
        assets: (json['assets'] as List<dynamic>)
            .map((e) => ExtractedAsset.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ImagePromptResponse {
  const ImagePromptResponse({required this.prompt});
  final String prompt;

  factory ImagePromptResponse.fromJson(Map<String, dynamic> json) =>
      ImagePromptResponse(prompt: json['prompt'] as String);
}

class ImageGenerationResponse {
  const ImageGenerationResponse({required this.url});
  final String url;

  factory ImageGenerationResponse.fromJson(Map<String, dynamic> json) =>
      ImageGenerationResponse(url: json['url'] as String);
}

class VideoPromptResponse {
  const VideoPromptResponse({required this.storyboard});
  final String storyboard;

  factory VideoPromptResponse.fromJson(Map<String, dynamic> json) =>
      VideoPromptResponse(storyboard: json['storyboard'] as String);
}

class VideoEnqueueResponse {
  const VideoEnqueueResponse({required this.jobId});
  final String jobId;

  factory VideoEnqueueResponse.fromJson(Map<String, dynamic> json) =>
      VideoEnqueueResponse(jobId: json['job_id'] as String);
}

enum JobStatus {
  pending,
  running,
  success,
  failed;

  static JobStatus fromString(String s) => JobStatus.values.firstWhere(
        (j) => j.name == s,
        orElse: () => JobStatus.pending,
      );
}

class VideoStatusResponse {
  const VideoStatusResponse({required this.jobId, required this.status, this.url, this.error});

  final String jobId;
  final JobStatus status;
  final String? url;
  final String? error;

  bool get isTerminal => status == JobStatus.success || status == JobStatus.failed;
  bool get isSuccess => status == JobStatus.success;

  factory VideoStatusResponse.fromJson(Map<String, dynamic> json) =>
      VideoStatusResponse(
        jobId: json['job_id'] as String,
        status: JobStatus.fromString(json['status'] as String),
        url: json['url'] as String?,
        error: json['error'] as String?,
      );
}

enum ProviderType {
  gemini,
  byteplus;

  String get headerValue => switch (this) {
        gemini => 'gemini',
        byteplus => 'bytedance',
      };

  static ProviderType fromString(String s) => ProviderType.values.firstWhere(
        (p) => p.name == s,
        orElse: () => ProviderType.gemini,
      );
}

enum UserTier {
  free,
  creator,
  studio;

  static UserTier fromString(String s) => UserTier.values.firstWhere(
        (t) => t.name == s,
        orElse: () => UserTier.free,
      );

  int get monthlyCredits => switch (this) {
        free => 200,
        creator => 3000,
        studio => 10000,
      };

  int? get maxProjects => switch (this) {
        free => 1,
        creator => null,
        studio => null,
      };
}

abstract final class CreditCost {
  static const int assetExtraction = 1;
  static const int imagePrompt = 1;
  static const int imageGeneration = 5;
  static const int videoPrompt = 3;
  static const int videoGeneration = 20;
  /// Cloud FFmpeg merge — flat fee regardless of scene count.
  static const int merge = 5;
}

// ── Generation settings ───────────────────────────────────────────────────────

/// Default art style used when no preference has been set for the project.
const kDefaultArtStyle = 'cinematic live-action';

/// Preset art styles shown in the style picker.
///
/// Users may also enter a free-form custom value. These presets cover the most
/// common visual directions for AI-generated storytelling content.
const kArtStylePresets = [
  kDefaultArtStyle,
  'painterly illustration with clean lines and rich color',
  '2D Japanese anime style',
  '3D animation CG style',
  'retro film grain',
];

/// Project-level generation settings stored in the Firestore project document.
///
/// The backend reads these values when `/image-prompt` and `/video-prompt` are
/// called and injects them into the AI input payload — the mobile request bodies
/// are unchanged. Settings are set at project creation and can be updated later.
class GenerationSettings {
  const GenerationSettings({
    this.artStyle = kDefaultArtStyle,
    this.videoSubtitles = false,
  });

  /// Visual rendering style applied to both image generation (rendering style)
  /// and video generation (closing block art style). One unified style governs
  /// the entire project's visual identity.
  final String artStyle;

  /// When `true`, the subtitle-free constraint is omitted from video prompts,
  /// allowing `【】` subtitle syntax in scene descriptions.
  final bool videoSubtitles;

  factory GenerationSettings.fromFirestore(Map<String, dynamic> data) =>
      GenerationSettings(
        artStyle: (data['art_style'] as String?)?.isNotEmpty == true
            ? data['art_style'] as String
            : kDefaultArtStyle,
        videoSubtitles: data['video_subtitles'] as bool? ?? false,
      );

  Map<String, dynamic> toFirestore() => {
        'art_style': artStyle,
        'video_subtitles': videoSubtitles,
      };

  GenerationSettings copyWith({String? artStyle, bool? videoSubtitles}) =>
      GenerationSettings(
        artStyle: artStyle ?? this.artStyle,
        videoSubtitles: videoSubtitles ?? this.videoSubtitles,
      );
}

// ── Firestore-backed project document ────────────────────────────────────────

/// Represents the Firestore project root document at
/// `users/{uid}/projects/{slug}`.
///
/// [slug] is the immutable document ID and GCS folder prefix, generated once
/// at project creation and never changed (even if [displayName] is updated).
class ProjectDocument {
  const ProjectDocument({
    required this.slug,
    required this.displayName,
    required this.createdAt,
    this.sceneCount = 0,
    this.completedSceneCount = 0,
    this.gcsFinalPath,
    this.generationSettings = const GenerationSettings(),
  });

  /// Immutable project slug — Firestore document ID and GCS folder prefix.
  final String slug;

  /// User-facing project name. Mutable; updating this does NOT change [slug].
  final String displayName;

  /// Project creation timestamp from the Firestore `created_at` field.
  final DateTime createdAt;

  /// Denormalized total scene count. Updated by workers on scene creation.
  final int sceneCount;

  /// Denormalized completed scene count (scenes with a `gcs_video_path` set).
  final int completedSceneCount;

  /// GCS path for the merged `final.mp4`. Non-null once a merge job completes.
  final String? gcsFinalPath;

  /// Project-level generation settings for image and video prompts.
  final GenerationSettings generationSettings;

  /// Fraction of scenes with a generated video (0.0–1.0).
  double get completionFraction =>
      sceneCount == 0 ? 0.0 : completedSceneCount / sceneCount;

  /// Parses a [ProjectDocument] from a Firestore snapshot data map.
  ///
  /// [id] is the Firestore document ID (the project slug).
  /// [data] is the raw `Map<String, dynamic>` from the snapshot.
  factory ProjectDocument.fromFirestore(
    String id,
    Map<String, dynamic> data,
  ) {
    // Firestore Timestamps are deserialized as `Timestamp` objects; fall back
    // to now() if the field is missing on a freshly created document that has
    // not yet received a server-side `created_at` write.
    DateTime createdAt;
    final raw = data['created_at'];
    if (raw != null && raw is Object) {
      // Use duck-typing to avoid importing cloud_firestore into models.dart.
      // Timestamp has a `.toDate()` method — call it reflectively.
      try {
        createdAt = (raw as dynamic).toDate() as DateTime;
      } catch (_) {
        createdAt = DateTime.now();
      }
    } else {
      createdAt = DateTime.now();
    }

    final settingsRaw = data['generation_settings'] as Map<String, dynamic>?;

    return ProjectDocument(
      slug: id,
      displayName: data['display_name'] as String? ?? id,
      createdAt: createdAt,
      sceneCount: data['scene_count'] as int? ?? 0,
      completedSceneCount: data['completed_scene_count'] as int? ?? 0,
      gcsFinalPath: data['gcs_final_path'] as String?,
      generationSettings: settingsRaw != null
          ? GenerationSettings.fromFirestore(settingsRaw)
          : const GenerationSettings(),
    );
  }
}

/// Represents a Firestore asset document at
/// `users/{uid}/projects/{slug}/assets/{asset_slug}` or
/// `users/{uid}/projects/{slug}/scenes/{n}/assets/{asset_slug}`.
class AssetDocument {
  const AssetDocument({
    required this.id,
    required this.name,
    required this.type,
    required this.description,
    this.promptBody,
    this.gcsImagePath,
  });

  final String id;
  final String name;
  final AssetType type;
  final String description;

  /// Generated image prompt text (`prompt_body` Firestore field). Null until
  /// a `/image-prompt` call completes and the backend writes it.
  final String? promptBody;

  /// GCS object path for the generated image.png. Null until the image worker
  /// completes. Null for pass-through reference assets (no independent image).
  final String? gcsImagePath;

  factory AssetDocument.fromFirestore(String id, Map<String, dynamic> data) =>
      AssetDocument(
        id: id,
        name: data['name'] as String? ?? id,
        type: AssetType.fromString(data['type'] as String? ?? 'character'),
        description: data['description'] as String? ?? '',
        promptBody: data['prompt_body'] as String?,
        gcsImagePath: data['gcs_image_path'] as String?,
      );
}

/// Represents a Firestore scene document at
/// `users/{uid}/projects/{slug}/scenes/{n}`.
class SceneDocument {
  const SceneDocument({
    required this.id,
    required this.sceneNumber,
    this.storyboardBody,
    this.gcsVideoPath,
  });

  final String id;
  final int sceneNumber;

  /// Generated storyboard prompt. Null until a `/video-prompt` call completes.
  final String? storyboardBody;

  /// GCS object path for the generated video.mp4. Null until the video worker
  /// completes.
  final String? gcsVideoPath;

  factory SceneDocument.fromFirestore(String id, Map<String, dynamic> data) =>
      SceneDocument(
        id: id,
        sceneNumber: data['scene_number'] as int? ?? int.tryParse(id) ?? 1,
        storyboardBody: data['storyboard_body'] as String?,
        gcsVideoPath: data['gcs_video_path'] as String?,
      );
}

// ── On-device job registry entry ─────────────────────────────────────────────

/// Represents a single entry in the Hive CE `job_registry` box.
///
/// Keyed by [jobId]. Tracks in-flight and recently completed generation jobs
/// so the UI can show live status even after app restarts.
///
/// Phase 1: in-memory only (no Hive CE dependency). Phase 2 will annotate
/// this class with `@HiveType` and generate an adapter.
class JobRegistryEntry {
  const JobRegistryEntry({
    required this.jobId,
    required this.type,
    required this.projectId,
    required this.status,
    required this.createdAt,
    this.sceneIndex,
    this.assetName,
    this.resolvedAt,
  });

  final String jobId;

  /// Job type: `'image'`, `'video'`, `'merge'`, `'assets'`, `'image_prompt'`,
  /// or `'video_prompt'`.
  final String type;

  /// Immutable project slug. Used to route FCM notifications to the correct
  /// project UI.
  final String projectId;

  final int? sceneIndex;
  final String? assetName;

  /// Job status: `'pending'`, `'running'`, `'success'`, or `'failed'`.
  final String status;

  final DateTime createdAt;

  /// Set when the job reaches a terminal state (success or failed).
  final DateTime? resolvedAt;

  bool get isTerminal => status == 'success' || status == 'failed';
  bool get isPending => status == 'pending' || status == 'running';

  JobRegistryEntry copyWith({String? status, DateTime? resolvedAt}) =>
      JobRegistryEntry(
        jobId: jobId,
        type: type,
        projectId: projectId,
        sceneIndex: sceneIndex,
        assetName: assetName,
        status: status ?? this.status,
        createdAt: createdAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
      );
}

// ── Legacy filesystem-based project model (Phase 2 compat) ───────────────────

/// On-device project metadata from the filesystem.
///
/// @deprecated Use [ProjectDocument] for Firestore-backed project lists.
/// This class is kept only for backward compat with Phase 2 cubits
/// (scene_cubit, story_cubit, asset_editor_cubit, editor_cubit) that still
/// reference [ProjectFileService]. It will be removed when those cubits are
/// migrated to Firestore in Phase 2.
class ProjectMeta {
  const ProjectMeta({
    required this.name,
    required this.directoryPath,
    required this.lastModified,
    required this.sceneCount,
    required this.completedSceneCount,
    this.totalSizeBytes,
  });

  final String name;
  final String directoryPath;
  final DateTime lastModified;
  final int sceneCount;
  final int completedSceneCount;
  final int? totalSizeBytes;

  double get completionFraction =>
      sceneCount == 0 ? 0 : completedSceneCount / sceneCount;
}

class ClipTrimState {
  const ClipTrimState({
    required this.sceneNumber,
    required this.inPoint,
    required this.outPoint,
    required this.totalDuration,
  });

  final int sceneNumber;
  final double inPoint;
  final double outPoint;
  final double totalDuration;

  double get trimmedDuration => outPoint - inPoint;
  static const double minDuration = 0.5;

  ClipTrimState copyWith({double? inPoint, double? outPoint}) => ClipTrimState(
        sceneNumber: sceneNumber,
        inPoint: inPoint ?? this.inPoint,
        outPoint: outPoint ?? this.outPoint,
        totalDuration: totalDuration,
      );

  Map<String, dynamic> toJson() => {
        'sceneNumber': sceneNumber,
        'inPoint': inPoint,
        'outPoint': outPoint,
        'totalDuration': totalDuration,
      };

  factory ClipTrimState.fromJson(Map<String, dynamic> json) => ClipTrimState(
        sceneNumber: json['sceneNumber'] as int,
        inPoint: (json['inPoint'] as num).toDouble(),
        outPoint: (json['outPoint'] as num).toDouble(),
        totalDuration: (json['totalDuration'] as num).toDouble(),
      );
}

/// Per-project GCS storage summary from `GET /projects/{slug}/storage`.
///
/// All byte values are 0 when the project has no generated media.
/// [totalBytes] = [imagesBytes] + [videosBytes] + [exportBytes].
class ProjectStorageSummary {
  const ProjectStorageSummary({
    required this.slug,
    required this.totalBytes,
    required this.imagesBytes,
    required this.videosBytes,
    required this.exportBytes,
  });

  final String slug;

  /// Sum of all image.png object sizes under {uid}/{slug}/.
  final int totalBytes;

  /// Sum of all image.png object sizes.
  final int imagesBytes;

  /// Sum of all scene video.mp4 object sizes.
  final int videosBytes;

  /// Size of final.mp4 (0 if no export yet).
  final int exportBytes;

  factory ProjectStorageSummary.fromJson(String slug, Map<String, dynamic> json) =>
      ProjectStorageSummary(
        slug: slug,
        totalBytes: json['total_bytes'] as int? ?? 0,
        imagesBytes: json['images_bytes'] as int? ?? 0,
        videosBytes: json['videos_bytes'] as int? ?? 0,
        exportBytes: json['export_bytes'] as int? ?? 0,
      );

  /// Returns a zeroed summary — used as a placeholder while the fetch is in flight
  /// or when the backend returns an error (non-blocking).
  factory ProjectStorageSummary.zero(String slug) => ProjectStorageSummary(
        slug: slug,
        totalBytes: 0,
        imagesBytes: 0,
        videosBytes: 0,
        exportBytes: 0,
      );
}

enum TransitionType {
  hardCut,
  fadeBlack,
  dissolve;

  /// Full display name shown in the transition picker.
  String get label => switch (this) {
        hardCut => 'Hard Cut',
        fadeBlack => 'Fade to Black',
        dissolve => 'Dissolve',
      };

  /// Abbreviated label shown on the small timeline indicator (≤ 4 chars).
  String get shortLabel => switch (this) {
        hardCut => 'Cut',
        fadeBlack => 'Fade',
        dissolve => 'Dslv',
      };

  /// JSON-safe string sent to `POST /merge` as `transition_to_next`.
  String get apiValue => switch (this) {
        hardCut => 'hard_cut',
        fadeBlack => 'fade_black',
        dissolve => 'dissolve',
      };
}
