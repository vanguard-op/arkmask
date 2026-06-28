import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;

import '../../../core/api/api_error.dart';
import '../../../core/api/ark_mask_api_client.dart';
import '../../../core/filesystem/project_file_service.dart';
import '../../../core/jobs/generation_job_manager.dart';
import '../../../core/models/models.dart';
import 'scene_state.dart';

/// Cubit for the Scene Detail Screen (FEAT-014, FEAT-015, FEAT-016).
///
/// Owns the read/write lifecycle for a scene's `ark.mdx` (storyboard) and
/// `video.mp4`, delegating generation to the backend API and persisting job
/// state via [GenerationJobManager] so status survives screen navigation.
class SceneCubit extends Cubit<SceneState> {
  SceneCubit({
    required this.projectName,
    required this.sceneNumber,
    required this.fileService,
    required this.apiClient,
    required this.jobManager,
  }) : super(SceneLoading());

  final String projectName;
  final int sceneNumber;
  final ProjectFileService fileService;
  final ArkMaskApiClient apiClient;
  final GenerationJobManager jobManager;

  Timer? _pollTimer;

  // ── Load ──────────────────────────────────────────────────────────────────

  Future<void> load() async {
    emit(SceneLoading());
    try {
      final tree = await fileService.readProjectTree(projectName);
      final sceneNode = tree.scenes.firstWhere(
        (s) => s.sceneNumber == sceneNumber,
        orElse: () => throw StateError('Scene $sceneNumber not found.'),
      );

      final sceneDirPath = sceneNode.directoryPath;
      final projectDir = p.dirname(p.dirname(sceneDirPath)); // scenes/N → scenes → project

      // Build scene assets with resolved image availability.
      final assets = <SceneAsset>[];
      for (final node in sceneNode.assets) {
        final isPassThrough = node.isPassThrough;
        bool hasImage;

        if (isPassThrough) {
          // Global pass-through: resolve image from global assets dir.
          final lastSegment = node.name.contains('/') ? node.name.split('/').last : node.name;
          final globalImagePath = p.join(projectDir, 'assets', lastSegment, 'image.png');
          hasImage = await File(globalImagePath).exists();
        } else {
          hasImage = await fileService.imageFileForAsset(node.directoryPath).exists();
        }

        assets.add(SceneAsset(
          name: node.name,
          dirPath: node.directoryPath,
          hasImage: hasImage,
          isGlobal: node.isGlobal,
          isPassThrough: isPassThrough,
          type: node.type,
          description: node.description,
        ));
      }

      final storyboard = await fileService.readArkMdx(sceneDirPath);
      final fullStory = await fileService.readStory(projectName);
      final sceneText = _extractSceneText(fullStory, sceneNumber);
      final hasVideo = await fileService.videoFileForScene(sceneDirPath).exists();

      emit(SceneLoaded(
        storyboard: storyboard,
        assets: assets,
        sceneText: sceneText,
        hasVideo: hasVideo,
        sceneDirPath: sceneDirPath,
        sceneNumber: sceneNumber,
      ));

      // Resume polling if a video job was running before this screen was built.
      final videoKey = GenerationJobManager.videoKey(sceneDirPath);
      if (jobManager.stateFor(videoKey) == GenerationJobState.running) {
        // We don't have the job ID anymore if we just navigated back; the
        // polling will be a no-op until the next generateVideo() call.
        // This guard just avoids resetting the job manager state on reload.
      }
    } catch (e) {
      emit(SceneError(message: e.toString()));
    }
  }

  // ── Tab switch ────────────────────────────────────────────────────────────

  void switchTab(int index) {
    final s = state;
    if (s is SceneLoaded) emit(s.copyWith(selectedTabIndex: index));
  }

  // ── Storyboard edits ──────────────────────────────────────────────────────

  /// Called when the storyboard `TextField` loses focus.
  Future<void> onStoryboardChanged(String body) async {
    final s = state;
    if (s is! SceneLoaded) return;
    final updated = s.storyboard.copyWith(storyboardBody: body);
    emit(s.copyWith(storyboard: updated));
    await fileService.writeArkMdx(s.sceneDirPath, updated);
  }

  // ── Generate Storyboard (FEAT-014) ────────────────────────────────────────

  Future<void> generateStoryboard() async {
    final s = state;
    if (s is! SceneLoaded) return;

    final storyboardKey = GenerationJobManager.storyboardKey(s.sceneDirPath);
    jobManager.markRunning(storyboardKey);
    emit(s.copyWith(
      isGeneratingStoryboard: true,
      storyboardError: null,
    ));

    try {
      final projectDir = p.dirname(p.dirname(s.sceneDirPath));
      final formData = await _buildStoryboardFormData(s, projectDir);

      final storyboardBody = await apiClient.generateVideoPrompt(formData: formData);

      // Persist to ark.mdx.
      final storyboard = SceneStoryboard(
        sceneNumber: s.sceneNumber,
        storyboardBody: storyboardBody,
      );
      await fileService.writeArkMdx(s.sceneDirPath, storyboard);

      jobManager.markDone(storyboardKey);
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          storyboard: storyboard,
          isGeneratingStoryboard: false,
          selectedTabIndex: 1, // auto-switch to Storyboard tab
        ));
      }
    } on ApiInsufficientCredits {
      jobManager.markFailed(storyboardKey, 'Insufficient credits');
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      jobManager.markFailed(storyboardKey, msg);
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: msg,
        ));
      }
    } catch (e) {
      jobManager.markFailed(storyboardKey, e.toString());
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingStoryboard: false,
          storyboardError: e.toString(),
        ));
      }
    }
  }

  Future<FormData> _buildStoryboardFormData(SceneLoaded s, String projectDir) async {
    // Append subtitle suppression to scene text.
    final sceneTextWithInstruction =
        '${s.sceneText}\n\nKeep it subtitle-free, avoid generating any text or subtitles in the video.';

    // Collect resolved images into a list so FormData.fromMap can send
    // multiple files under the same key without deduplication.
    final images = <MultipartFile>[];
    for (final asset in s.assets) {
      final imagePath = _resolveImagePath(asset, projectDir);
      if (await File(imagePath).exists()) {
        images.add(await MultipartFile.fromFile(
          imagePath,
          filename: '${asset.name.split('/').last}.png',
        ));
      }
    }

    return FormData.fromMap({
      'scene_text': sceneTextWithInstruction,
      if (images.isNotEmpty) 'images[]': images,
    });
  }

  // ── Generate Video (FEAT-016) ─────────────────────────────────────────────

  Future<void> generateVideo() async {
    final s = state;
    if (s is! SceneLoaded) return;

    final videoKey = GenerationJobManager.videoKey(s.sceneDirPath);
    jobManager.markRunning(videoKey);
    emit(s.copyWith(
      isGeneratingVideo: true,
      videoError: null,
    ));

    try {
      final projectDir = p.dirname(p.dirname(s.sceneDirPath));
      final formData = await _buildVideoFormData(s, projectDir);

      final jobId = await apiClient.generateVideo(formData: formData);

      // Begin polling — runs even if the user navigates away.
      _startPolling(jobId: jobId, sceneDirPath: s.sceneDirPath);
    } on ApiInsufficientCredits {
      jobManager.markFailed(videoKey, 'Insufficient credits');
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: '__credits__',
        ));
      }
    } on ApiError catch (e) {
      final msg = _apiErrorMessage(e);
      jobManager.markFailed(videoKey, msg);
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: msg,
        ));
      }
    } catch (e) {
      jobManager.markFailed(videoKey, e.toString());
      if (!isClosed) {
        emit((state as SceneLoaded).copyWith(
          isGeneratingVideo: false,
          videoError: e.toString(),
        ));
      }
    }
  }

  Future<FormData> _buildVideoFormData(SceneLoaded s, String projectDir) async {
    final images = <MultipartFile>[];
    for (final asset in s.assets) {
      final imagePath = _resolveImagePath(asset, projectDir);
      if (await File(imagePath).exists()) {
        images.add(await MultipartFile.fromFile(
          imagePath,
          filename: '${asset.name.split('/').last}.png',
        ));
      }
    }

    return FormData.fromMap({
      'storyboard': s.storyboard.storyboardBody,
      if (images.isNotEmpty) 'images[]': images,
    });
  }

  /// Resolves the image file path for an asset given the project dir.
  String _resolveImagePath(SceneAsset asset, String projectDir) {
    if (asset.isPassThrough) {
      final lastSegment =
          asset.name.contains('/') ? asset.name.split('/').last : asset.name;
      return p.join(projectDir, 'assets', lastSegment, 'image.png');
    }
    return p.join(asset.dirPath, 'image.png');
  }

  // ── Video polling ─────────────────────────────────────────────────────────

  void _startPolling({required String jobId, required String sceneDirPath}) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      await _pollOnce(
        jobId: jobId,
        sceneDirPath: sceneDirPath,
        timer: timer,
      );
    });
  }

  Future<void> _pollOnce({
    required String jobId,
    required String sceneDirPath,
    required Timer timer,
  }) async {
    final videoKey = GenerationJobManager.videoKey(sceneDirPath);
    try {
      final raw = await apiClient.getVideoJobStatus(jobId: jobId);
      final status = VideoStatusResponse.fromJson(raw);

      if (status.isTerminal) {
        timer.cancel();
        if (status.isSuccess && status.url != null) {
          // Download and save the video.
          try {
            final bytes = await apiClient.downloadBytes(status.url!);
            final videoFile = fileService.videoFileForScene(sceneDirPath);
            await videoFile.writeAsBytes(bytes);
            jobManager.markDone(videoKey);
            if (!isClosed && state is SceneLoaded) {
              emit((state as SceneLoaded).copyWith(
                isGeneratingVideo: false,
                hasVideo: true,
              ));
            }
          } catch (e) {
            jobManager.markFailed(videoKey, 'Failed to save video: $e');
            if (!isClosed && state is SceneLoaded) {
              emit((state as SceneLoaded).copyWith(
                isGeneratingVideo: false,
                videoError: 'Failed to save video: $e',
              ));
            }
          }
        } else {
          final errMsg = status.error ?? 'Video generation failed.';
          jobManager.markFailed(videoKey, errMsg);
          if (!isClosed && state is SceneLoaded) {
            emit((state as SceneLoaded).copyWith(
              isGeneratingVideo: false,
              videoError: errMsg,
            ));
          }
        }
      }
    } catch (_) {
      // Transient network error — keep polling.
    }
  }

  // ── Error dismissal ───────────────────────────────────────────────────────

  void clearStoryboardError() {
    final s = state;
    if (s is SceneLoaded) emit(s.copyWith(storyboardError: null));
  }

  void clearVideoError() {
    final s = state;
    if (s is SceneLoaded) emit(s.copyWith(videoError: null));
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  static String _apiErrorMessage(ApiError e) => switch (e) {
        ApiConflict(:final message) => message,
        ApiValidationError(:final detail) => detail,
        ApiServerError(:final message) => message,
        ApiNetworkError(:final message) => message,
        ApiUnknownError(:final message) => message,
        ApiInsufficientCredits() => 'Insufficient credits',
        ApiUnauthorized() => 'Unauthorized',
      };

  /// Extracts the body text for [sceneNumber] from the full `story.mdx` content.
  ///
  /// The story format uses `# N` headings as scene delimiters. Everything
  /// between `# N` and the next `# N+1` heading (or end of file) is the
  /// body for scene N.
  static String _extractSceneText(String fullStory, int sceneNumber) {
    // Split on lines starting with "# " followed by a number.
    final lines = fullStory.split('\n');
    final body = StringBuffer();
    bool inScene = false;

    for (final line in lines) {
      final heading = RegExp(r'^#\s+(\d+)\s*$').firstMatch(line.trim());
      if (heading != null) {
        final n = int.parse(heading.group(1)!);
        if (n == sceneNumber) {
          inScene = true;
          continue; // skip the heading line itself
        } else if (inScene) {
          break; // reached the next scene heading — stop
        }
      } else if (inScene) {
        body.writeln(line);
      }
    }

    return body.toString().trim();
  }

  @override
  Future<void> close() {
    _pollTimer?.cancel();
    return super.close();
  }
}
