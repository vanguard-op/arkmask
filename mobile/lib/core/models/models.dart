// Data models for ArkMask, derived from docs/ArkMask/schema.md.

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
}

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

enum TransitionType {
  hardCut,
  fadeBlack,
  dissolve;

  String get label => switch (this) {
        hardCut => 'Cut',
        fadeBlack => 'Fade to Black',
        dissolve => 'Dissolve',
      };
}
