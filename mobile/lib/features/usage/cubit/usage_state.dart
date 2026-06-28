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

  /// Human-readable label for the event type.
  String get typeLabel => switch (type) {
        'image-prompt' => 'Image Prompt',
        'image' => 'Image Generation',
        'video-prompt' => 'Storyboard',
        'video' => 'Video Generation',
        _ => type,
      };

  factory UsageEvent.fromJson(Map<String, dynamic> json) => UsageEvent(
        id: json['id']?.toString() ?? '',
        type: json['type'] as String? ?? '',
        provider: json['provider'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
            : DateTime.now(),
        costCredits: (json['cost_credits'] as num?)?.toInt() ?? 0,
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
      : allEvents.where((e) => e.type == filterType).toList();

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
