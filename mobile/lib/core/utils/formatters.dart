import 'package:intl/intl.dart';

/// Formats a [DateTime] as a human-readable relative or absolute label.
///
/// Examples:
/// - "Today" / "Yesterday"
/// - "Mon, Jun 23"
/// - "Jan 12, 2025"
String formatLastModified(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final dateDay = DateTime(date.year, date.month, date.day);

  if (dateDay == today) return 'Today';
  if (dateDay == yesterday) return 'Yesterday';
  if (now.year == date.year) return DateFormat('EEE, MMM d').format(date);
  return DateFormat('MMM d, yyyy').format(date);
}

/// Formats bytes into a human-readable size string.
///
/// Examples: "2.4 MB", "847 KB", "1.1 GB"
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Formats a credit count with thousands separator.
///
/// Example: 1240 → "1,240 cr"
String formatCredits(int credits) {
  return '${NumberFormat('#,##0').format(credits)} cr';
}

/// Formats a byte count into a human-readable string (KB, MB, GB).
///
/// Uses compact units with no space between number and suffix, e.g.
/// "512B", "3.4KB", "12.7MB", "1.02GB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
}

/// Formats a duration in seconds as `m:ss`.
///
/// Example: 93.5 → "1:33"
String formatDuration(double seconds) {
  final total = seconds.truncate();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
