import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/api/ark_mask_api_client.dart';
import 'usage_state.dart';

/// Cubit for the Usage Dashboard screen (FEAT-024).
///
/// Fetches generation event history from GET /usage and exposes
/// per-type filtering. Events are never re-fetched on filter change —
/// all filtering is done client-side over the cached [allEvents] list.
class UsageCubit extends Cubit<UsageState> {
  UsageCubit({required this.apiClient}) : super(const UsageLoading());

  final ArkMaskApiClient apiClient;

  /// Fetches all generation events from the backend.
  Future<void> load() async {
    emit(const UsageLoading());
    try {
      final raw = await apiClient.getUsageEvents();
      final events = raw
          .whereType<Map<String, dynamic>>()
          .map(UsageEvent.fromJson)
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp)); // newest first
      emit(UsageLoaded(allEvents: events));
    } catch (e) {
      emit(const UsageError(
        message: 'Failed to load usage history. Check your connection.',
      ));
    }
  }

  /// Filters visible events to [type]. Pass null to show all types.
  void setTypeFilter(String? type) {
    final s = state;
    if (s is! UsageLoaded) return;
    emit(s.copyWith(filterType: type));
  }
}
