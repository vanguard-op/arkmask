import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

/// A single generation event returned by GET /usage.
@immutable
class UsageEvent extends Equatable {
  const UsageEvent({
    required this.id,
    required this.type,
    required this.provider,
    required this.timestamp,
    required this.costCredits,
  });

  /// Event type identifier (e.g. "image-prompt", "image", "video-prompt", "video").
  final String type;

  final String id;

  /// AI provider used for this event (e.g. "gemini", "bytedance").
  final String provider;

  final DateTime timestamp;

  /// Credit cost for this event (from monetization.md cost schedule).
  final int costCredits;

  /// Canonical, hyphen/underscore-and-slash-insensitive form of [type].
  ///
  /// Usage events are written by two different code paths that don't agree
  /// on naming:
  ///  - backend/app/routers/generation.py's synchronous fallback (used when
  ///    Cloud Tasks isn't configured, e.g. local dev) writes hyphenated,
  ///    slash-prefixed endpoints: "/image-prompt", "/video-prompt",
  ///    "/refine-story".
  ///  - workers/app/jobs.py's `deduct_credits` (the production path, called
  ///    from the Cloud Tasks task handlers) writes `f"/{job_type}"` where
  ///    `job_type` uses underscores and drops "-story": "/image_prompt",
  ///    "/video_prompt", "/refine".
  /// Normalizing to a single underscore-based, slash-free key lets one
  /// switch statement handle events from either path.
  String get normalizedType {
    var key = type.startsWith('/') ? type.substring(1) : type;
    key = key.replaceAll('-', '_');
    if (key == 'refine_story') key = 'refine';
    return key;
  }

  /// Human-readable label for the event type.
  String get typeLabel => switch (normalizedType) {
        'image_prompt' => 'Image Prompt',
        'image' => 'Image Generation',
        'video_prompt' => 'Storyboard',
        'video' => 'Video Generation',
        'assets' => 'Asset Extraction',
        'refine' => 'Refine Story',
        'merge' => 'Video Merge',
        'image_describe' => 'Image Description',
        _ => normalizedType,
      };

  // Backend's GET /usage (UsageEventResponse in app/schemas/auth.py) returns
  // `endpoint` and `credits_deducted` — not `type`/`id`/`cost_credits`. Those
  // mismatched keys meant every field silently fell back to its default
  // (empty string / 0), which is why every event showed "0 cr" and the type
  // label came out blank/unmapped. There's also no `id` field in the
  // backend response, so events are keyed by endpoint+timestamp instead.
  factory UsageEvent.fromJson(Map<String, dynamic> json) => UsageEvent(
        id: '${json['endpoint']}-${json['timestamp']}',
        type: json['endpoint'] as String? ?? '',
        provider: json['provider'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
            : DateTime.now(),
        costCredits: (json['credits_deducted'] as num?)?.toInt() ?? 0,
      );

  @override
  List<Object?> get props => [id, type, provider, timestamp, costCredits];
}

sealed class UsageState extends Equatable {
  const UsageState();
}

class UsageLoading extends UsageState {
  const UsageLoading();
  @override
  List<Object?> get props => [];
}

class UsageLoaded extends UsageState {
  const UsageLoaded({
    required this.allEvents,
    this.filterType,
  });

  final List<UsageEvent> allEvents;

  /// Null = show all types; otherwise filters to matching events.
  final String? filterType;

  List<UsageEvent> get filteredEvents => filterType == null
      ? allEvents
      : allEvents.where((e) => e.normalizedType == filterType).toList();

  int get totalCostCredits =>
      filteredEvents.fold(0, (sum, e) => sum + e.costCredits);

  UsageLoaded copyWith({
    List<UsageEvent>? allEvents,
    Object? filterType = _sentinel,
  }) =>
      UsageLoaded(
        allEvents: allEvents ?? this.allEvents,
        filterType: identical(filterType, _sentinel)
            ? this.filterType
            : filterType as String?,
      );

  @override
  List<Object?> get props => [allEvents, filterType];
}

class UsageError extends UsageState {
  const UsageError({required this.message});
  final String message;
  @override
  List<Object?> get props => [message];
}

const Object _sentinel = Object();
